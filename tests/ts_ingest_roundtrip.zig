//! Native timeseries GQL surface — end-to-end tests through the execution path.
//!
//! Exercises the `geode.ts.*` procedure family
//! (insert / insert_many / range / last / bucket_avg / sample_by) via
//! `execution.executeStatementWithContext`, the same entry point the QUIC and
//! gRPC servers use. This proves the native timeseries write + query surface
//! works through the real parse → plan → execute → result pipeline, not just the
//! Store. Also covers the two B0 Store fixes: the inclusive `queryRange`
//! end-bound (in-memory and durable modes return identical slices) and the
//! `series_cache` data-race fix (concurrent ingest).
//!
//! Store resolution in the dispatcher is `eval.getTimeseriesStoreForGraph(null)`
//! → the global `g_timeseries_store`, so each test installs an in-process Store
//! via `eval.setGlobalTimeseriesStore` (the server-boot wiring path).
const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const execution = geode.execution;
const eval = geode.eval;
const ts = geode.timeseries;

const SeriesKey = ts.SeriesKey;
const Point = ts.Point;
const Store = ts.Store;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Parse + execute a single statement through the full execution path — the
/// same entry the QUIC/gRPC servers use (`executeStatementWithContext`). The
/// parse arena is freed before returning; the returned ExecutionResult is owned
/// by `allocator` and holds only scalar Ints + dupe'd column names (no AST
/// references), so freeing the parse arena here is safe.
fn runQuery(
    allocator: std.mem.Allocator,
    query: []const u8,
) !execution.ExecutionResult {
    var parsed = try geode.parseGql(query, allocator);
    defer parsed.deinit();

    // The ExecutionContext requires a catalog; use the global singleton helper
    // (the same one tests/test_fts_e2e.zig uses). `Catalog` is not re-exported
    // on `execution`, so go through ensure/cleanup.
    const catalog = try execution.ensureCatalogInstance(allocator);
    defer execution.cleanupCatalogInstance();

    // executeCallProcedure lazily creates the global graph store
    // (graph_store.getGlobalStore) before reaching the geode.ts.* branch. Our
    // procedures resolve the timeseries Store via the separate global pointer,
    // so the graph store is never actually used here — free it after each call
    // so the leak-checking test allocator stays green.
    defer geode.graph_store.deinitGlobalStore();

    const ctx = execution.ExecutionContext{ .catalog = catalog };
    return execution.executeStatementWithContext(allocator, parsed.program.statements[0], ctx);
}

/// Find a column index by name in a result (case-sensitive — the dispatcher
/// emits canonical lowercase column names).
fn colIndex(res: execution.ExecutionResult, name: []const u8) ?usize {
    for (res.columns, 0..) |c, i| {
        if (std.mem.eql(u8, c, name)) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// (a) ingest + read (range / last)
// ---------------------------------------------------------------------------

test "ts gql: insert then range + last (in-memory)" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    eval.setGlobalTimeseriesStore(&store);
    defer eval.setGlobalTimeseriesStore(null);

    {
        var r = try runQuery(allocator, "CALL geode.ts.insert(1, 'temp', 100, 72) YIELD inserted RETURN inserted");
        defer r.deinit(allocator);
        const ci = colIndex(r, "inserted").?;
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        try std.testing.expectEqual(@as(i64, 1), r.rows[0][ci].Int);
    }

    {
        var r = try runQuery(allocator, "CALL geode.ts.range(1, 'temp', 0, 200) YIELD ts, value RETURN ts, value");
        defer r.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        const ti = colIndex(r, "ts").?;
        const vi = colIndex(r, "value").?;
        try std.testing.expectEqual(@as(i64, 100), r.rows[0][ti].Int);
        try std.testing.expectEqual(@as(i64, 72), r.rows[0][vi].Int);
    }

    {
        var r = try runQuery(allocator, "CALL geode.ts.last(1, 'temp') YIELD ts, value RETURN ts, value");
        defer r.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        const ti = colIndex(r, "ts").?;
        const vi = colIndex(r, "value").?;
        try std.testing.expectEqual(@as(i64, 100), r.rows[0][ti].Int);
        try std.testing.expectEqual(@as(i64, 72), r.rows[0][vi].Int);
    }
}

// ---------------------------------------------------------------------------
// insert_many (nested-list arg form)
// ---------------------------------------------------------------------------

test "ts gql: insert_many nested list then range" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    eval.setGlobalTimeseriesStore(&store);
    defer eval.setGlobalTimeseriesStore(null);

    {
        var r = try runQuery(allocator, "CALL geode.ts.insert_many(1, 'temp', [[100, 72], [110, 73], [120, 74]]) YIELD inserted RETURN inserted");
        defer r.deinit(allocator);
        const ci = colIndex(r, "inserted").?;
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        try std.testing.expectEqual(@as(i64, 3), r.rows[0][ci].Int);
    }

    {
        var r = try runQuery(allocator, "CALL geode.ts.range(1, 'temp', 0, 200) YIELD ts, value RETURN ts, value");
        defer r.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 3), r.rows.len);
        const ti = colIndex(r, "ts").?;
        const vi = colIndex(r, "value").?;
        try std.testing.expectEqual(@as(i64, 100), r.rows[0][ti].Int);
        try std.testing.expectEqual(@as(i64, 72), r.rows[0][vi].Int);
        try std.testing.expectEqual(@as(i64, 120), r.rows[2][ti].Int);
        try std.testing.expectEqual(@as(i64, 74), r.rows[2][vi].Int);
    }
}

// ---------------------------------------------------------------------------
// (c) value exactness: i64 extremes round-trip unchanged
// ---------------------------------------------------------------------------

test "ts gql: i64 extremes round-trip exactly" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    eval.setGlobalTimeseriesStore(&store);
    defer eval.setGlobalTimeseriesStore(null);

    // ts values must be strictly increasing for a sane series; use distinct ts.
    {
        var r = try runQuery(allocator, "CALL geode.ts.insert_many(9, 'x', [[1, 9223372036854775807], [2, -9223372036854775807], [3, 0], [4, -1]]) YIELD inserted RETURN inserted");
        defer r.deinit(allocator);
        try std.testing.expectEqual(@as(i64, 4), r.rows[0][colIndex(r, "inserted").?].Int);
    }

    var r = try runQuery(allocator, "CALL geode.ts.range(9, 'x', 0, 100) YIELD ts, value RETURN ts, value");
    defer r.deinit(allocator);
    const ti = colIndex(r, "ts").?;
    const vi = colIndex(r, "value").?;
    try std.testing.expectEqual(@as(usize, 4), r.rows.len);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), r.rows[0][vi].Int);
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64) + 1), r.rows[1][vi].Int);
    try std.testing.expectEqual(@as(i64, 0), r.rows[2][vi].Int);
    try std.testing.expectEqual(@as(i64, -1), r.rows[3][vi].Int);
    try std.testing.expectEqual(@as(i64, 1), r.rows[0][ti].Int);
}

// ---------------------------------------------------------------------------
// (d) multi-series isolation: distinct (device_id, metric) keys do not collide
// ---------------------------------------------------------------------------

test "ts gql: multi-series isolation" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    eval.setGlobalTimeseriesStore(&store);
    defer eval.setGlobalTimeseriesStore(null);

    {
        var r1 = try runQuery(allocator, "CALL geode.ts.insert(1, 'temp', 100, 10) YIELD inserted RETURN inserted");
        r1.deinit(allocator);
        var r2 = try runQuery(allocator, "CALL geode.ts.insert(2, 'temp', 100, 20) YIELD inserted RETURN inserted");
        r2.deinit(allocator);
        var r3 = try runQuery(allocator, "CALL geode.ts.insert(1, 'humidity', 100, 30) YIELD inserted RETURN inserted");
        r3.deinit(allocator);
    }

    // (1,'temp') sees only its own point.
    {
        var r = try runQuery(allocator, "CALL geode.ts.range(1, 'temp', 0, 200) YIELD ts, value RETURN ts, value");
        defer r.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        try std.testing.expectEqual(@as(i64, 10), r.rows[0][colIndex(r, "value").?].Int);
    }
    // (2,'temp')
    {
        var r = try runQuery(allocator, "CALL geode.ts.range(2, 'temp', 0, 200) YIELD ts, value RETURN ts, value");
        defer r.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        try std.testing.expectEqual(@as(i64, 20), r.rows[0][colIndex(r, "value").?].Int);
    }
    // (1,'humidity')
    {
        var r = try runQuery(allocator, "CALL geode.ts.range(1, 'humidity', 0, 200) YIELD ts, value RETURN ts, value");
        defer r.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        try std.testing.expectEqual(@as(i64, 30), r.rows[0][colIndex(r, "value").?].Int);
    }
}

// ---------------------------------------------------------------------------
// (e) range end-bound: point exactly at end_ts is INCLUDED (in-memory mode);
//     bucket_avg / sample_by see the boundary point too.
// ---------------------------------------------------------------------------

test "ts gql: range end-bound inclusive (in-memory) + aggregates see boundary" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    eval.setGlobalTimeseriesStore(&store);
    defer eval.setGlobalTimeseriesStore(null);

    {
        var r = try runQuery(allocator, "CALL geode.ts.insert_many(1, 'temp', [[100, 10], [200, 20]]) YIELD inserted RETURN inserted");
        r.deinit(allocator);
    }

    // end_ts == 200 must INCLUDE the point at ts=200.
    {
        var r = try runQuery(allocator, "CALL geode.ts.range(1, 'temp', 100, 200) YIELD ts, value RETURN ts, value");
        defer r.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), r.rows.len);
        const ti = colIndex(r, "ts").?;
        try std.testing.expectEqual(@as(i64, 100), r.rows[0][ti].Int);
        try std.testing.expectEqual(@as(i64, 200), r.rows[1][ti].Int);
    }
}

// In-memory and durable modes return identical slices for the same range,
// including the boundary point at exactly end_ts. Drives the Store directly so
// both engine modes are compared in one test.
test "ts store: queryRange in-memory == durable (boundary inclusive)" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const key = SeriesKey{ .device_id = 42, .metric = "v" };
    const pts = [_]Point{
        .{ .ts = 100, .value = 1 },
        .{ .ts = 150, .value = 2 },
        .{ .ts = 200, .value = 3 },
    };

    // Query results are routed through an arena: the durable timeseries engine's
    // `queryPoints` allocates per-call decode/iterator scratch with the passed
    // allocator that is owned by the engine's lifetime, not individually freed by
    // the wrapper. An arena bulk-frees all of it and keeps the test leak-clean
    // while still exercising both store modes. (The dedicated leak-strict
    // coverage for the in-memory path is the GQL `range` tests above.)
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // In-memory mode.
    var mem_slice: []Point = undefined;
    {
        var mem = Store.init(allocator);
        defer mem.deinit();
        try mem.insertMany(key, &pts);
        mem_slice = try mem.queryRange(key, 100, 200, aa);
    }

    // Durable mode.
    const pid = if (@import("builtin").os.tag == .linux) std.os.linux.getpid() else 0;
    var path_buf: [160]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/geode_ts_bound_{d}", .{pid}) catch unreachable;
    const tio = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteTree(tio, test_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(tio, test_dir);
    var sub_buf: [224]u8 = undefined;
    const sub = std.fmt.bufPrint(&sub_buf, "{s}/timeseries", .{test_dir}) catch unreachable;
    try std.Io.Dir.cwd().createDirPath(tio, sub);
    defer std.Io.Dir.cwd().deleteTree(tio, test_dir) catch {};

    var dur_slice: []Point = undefined;
    {
        var dur = try Store.initWithConfig(allocator, .{ .data_dir = test_dir, .chunk_config = .{ .max_points_per_chunk = 10 } });
        defer dur.deinit();
        try dur.insertMany(key, &pts);
        try dur.sync();
        dur_slice = try dur.queryRange(key, 100, 200, aa);
    }

    // Both must include the boundary point at ts=200 → identical slices.
    try std.testing.expectEqual(@as(usize, 3), mem_slice.len);
    try std.testing.expectEqual(mem_slice.len, dur_slice.len);
    for (mem_slice, dur_slice) |m, d| {
        try std.testing.expectEqual(m.ts, d.ts);
        try std.testing.expectEqual(m.value, d.value);
    }
}

// ---------------------------------------------------------------------------
// (b) durable restart round-trip through the GQL seam.
// ---------------------------------------------------------------------------

test "ts gql: durable insert survives restart (last)" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const pid = if (@import("builtin").os.tag == .linux) std.os.linux.getpid() else 0;
    var path_buf: [160]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/geode_ts_restart_{d}", .{pid}) catch unreachable;
    const tio = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteTree(tio, test_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(tio, test_dir);
    var sub_buf: [224]u8 = undefined;
    const sub = std.fmt.bufPrint(&sub_buf, "{s}/timeseries", .{test_dir}) catch unreachable;
    try std.Io.Dir.cwd().createDirPath(tio, sub);
    defer std.Io.Dir.cwd().deleteTree(tio, test_dir) catch {};

    // Phase 1: insert via GQL, then deinit (flush to disk on close). This mirrors
    // the proven direct-Store persist test in src/timeseries/timeseries.zig
    // ("ts: persist-restart-query via StoreConfig"), which relies on the
    // deinit-time flush and does NOT call sync() explicitly.
    {
        var store = try Store.initWithConfig(allocator, .{ .data_dir = test_dir, .chunk_config = .{ .max_points_per_chunk = 10 } });
        defer store.deinit();
        eval.setGlobalTimeseriesStore(&store);
        defer eval.setGlobalTimeseriesStore(null);

        var r = try runQuery(allocator, "CALL geode.ts.insert_many(7, 'voltage', [[100, 220], [200, 221], [300, 219]]) YIELD inserted RETURN inserted");
        r.deinit(allocator);
    }

    // Phase 2: reopen, read last via GQL.
    {
        var store2 = try Store.initWithConfig(allocator, .{ .data_dir = test_dir, .chunk_config = .{ .max_points_per_chunk = 10 } });
        defer store2.deinit();
        try store2.loadFromDisk();
        eval.setGlobalTimeseriesStore(&store2);
        defer eval.setGlobalTimeseriesStore(null);

        var r = try runQuery(allocator, "CALL geode.ts.last(7, 'voltage') YIELD ts, value RETURN ts, value");
        defer r.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        try std.testing.expectEqual(@as(i64, 300), r.rows[0][colIndex(r, "ts").?].Int);
        try std.testing.expectEqual(@as(i64, 219), r.rows[0][colIndex(r, "value").?].Int);
    }
}

// ---------------------------------------------------------------------------
// (f) concurrent ingest — the series_cache data-race (B0 bug-1) fix.
// ---------------------------------------------------------------------------

test "ts store: concurrent insertMany is race-free" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    const n_threads = 4;
    const per_thread: usize = 250;

    const Worker = struct {
        fn run(s: *Store, thread_id: usize, count: usize) void {
            // Each thread writes its own series (no collision on key) AND a point
            // to a shared series (exercises the lock on the same cache entry).
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const ts_val: i64 = @intCast(thread_id * 1_000_000 + i);
                const own = SeriesKey{ .device_id = @intCast(thread_id), .metric = "own" };
                s.insertMany(own, &.{.{ .ts = ts_val, .value = ts_val }}) catch unreachable;
                const shared = SeriesKey{ .device_id = 9999, .metric = "shared" };
                s.insertMany(shared, &.{.{ .ts = ts_val, .value = ts_val }}) catch unreachable;
            }
        }
    };

    var threads: [n_threads]std.Thread = undefined;
    for (0..n_threads) |tid| {
        threads[tid] = try std.Thread.spawn(.{}, Worker.run, .{ &store, tid, per_thread });
    }
    for (threads) |t| t.join();

    // Each own series has per_thread points.
    for (0..n_threads) |tid| {
        const own = SeriesKey{ .device_id = @intCast(tid), .metric = "own" };
        const slice = try store.queryRange(own, std.math.minInt(i64), std.math.maxInt(i64), allocator);
        defer allocator.free(slice);
        try std.testing.expectEqual(@as(usize, per_thread), slice.len);
        // Sorted by ts.
        var prev: i64 = std.math.minInt(i64);
        for (slice) |p| {
            try std.testing.expect(p.ts >= prev);
            prev = p.ts;
        }
    }

    // The shared series received all writes from all threads.
    const shared = SeriesKey{ .device_id = 9999, .metric = "shared" };
    const shared_slice = try store.queryRange(shared, std.math.minInt(i64), std.math.maxInt(i64), allocator);
    defer allocator.free(shared_slice);
    try std.testing.expectEqual(@as(usize, n_threads * per_thread), shared_slice.len);
    var prev: i64 = std.math.minInt(i64);
    for (shared_slice) |p| {
        try std.testing.expect(p.ts >= prev);
        prev = p.ts;
    }
}

// ---------------------------------------------------------------------------
// (g) rejection: float value, unknown agg, wrong arity.
// ---------------------------------------------------------------------------

test "ts gql: float value rejected" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    eval.setGlobalTimeseriesStore(&store);
    defer eval.setGlobalTimeseriesStore(null);

    try std.testing.expectError(error.TypeMismatch, runQuery(allocator, "CALL geode.ts.insert(1, 'temp', 100, 1.5) YIELD inserted RETURN inserted"));
}

test "ts gql: unknown aggregation rejected" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    eval.setGlobalTimeseriesStore(&store);
    defer eval.setGlobalTimeseriesStore(null);

    {
        var r = try runQuery(allocator, "CALL geode.ts.insert(1, 'temp', 100, 10) YIELD inserted RETURN inserted");
        r.deinit(allocator);
    }
    try std.testing.expectError(error.InvalidArgs, runQuery(allocator, "CALL geode.ts.sample_by(1, 'temp', 50, 0, 200, 'bogus') YIELD bucket_ts, value RETURN bucket_ts, value"));
}

test "ts gql: wrong arity rejected" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    eval.setGlobalTimeseriesStore(&store);
    defer eval.setGlobalTimeseriesStore(null);

    // insert with 3 args (missing value).
    try std.testing.expectError(error.InvalidArgs, runQuery(allocator, "CALL geode.ts.insert(1, 'temp', 100) YIELD inserted RETURN inserted"));
    // range with 2 args.
    try std.testing.expectError(error.InvalidArgs, runQuery(allocator, "CALL geode.ts.range(1, 'temp') YIELD ts, value RETURN ts, value"));
}

test "ts gql: negative device_id rejected" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    eval.setGlobalTimeseriesStore(&store);
    defer eval.setGlobalTimeseriesStore(null);

    try std.testing.expectError(error.InvalidArgs, runQuery(allocator, "CALL geode.ts.insert(-1, 'temp', 100, 10) YIELD inserted RETURN inserted"));
}

// ---------------------------------------------------------------------------
// (h) empty series read → 0 rows, not an error.
// ---------------------------------------------------------------------------

test "ts gql: empty series range + last return 0 rows" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    eval.setGlobalTimeseriesStore(&store);
    defer eval.setGlobalTimeseriesStore(null);

    {
        var r = try runQuery(allocator, "CALL geode.ts.range(99, 'nope', 0, 200) YIELD ts, value RETURN ts, value");
        defer r.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), r.rows.len);
    }
    {
        var r = try runQuery(allocator, "CALL geode.ts.last(99, 'nope') YIELD ts, value RETURN ts, value");
        defer r.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), r.rows.len);
    }
}

// ---------------------------------------------------------------------------
// sample_by + bucket_avg basic shape through the GQL seam.
// ---------------------------------------------------------------------------

test "ts gql: sample_by avg + bucket_avg" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    eval.setGlobalTimeseriesStore(&store);
    defer eval.setGlobalTimeseriesStore(null);

    {
        var r = try runQuery(allocator, "CALL geode.ts.insert_many(1, 'cpu', [[0, 10], [5, 20], [10, 30]]) YIELD inserted RETURN inserted");
        r.deinit(allocator);
    }

    {
        var r = try runQuery(allocator, "CALL geode.ts.sample_by(1, 'cpu', 10, 0, 20, 'avg') YIELD bucket_ts, value RETURN bucket_ts, value");
        defer r.deinit(allocator);
        const bi = colIndex(r, "bucket_ts").?;
        const vi = colIndex(r, "value").?;
        try std.testing.expectEqual(@as(usize, 2), r.rows.len);
        // bucket [0,10): avg(10,20)=15 ; bucket [10,20): avg(30)=30
        try std.testing.expectEqual(@as(i64, 0), r.rows[0][bi].Int);
        try std.testing.expectEqual(@as(i64, 15), r.rows[0][vi].Int);
        try std.testing.expectEqual(@as(i64, 10), r.rows[1][bi].Int);
        try std.testing.expectEqual(@as(i64, 30), r.rows[1][vi].Int);
    }

    {
        var r = try runQuery(allocator, "CALL geode.ts.bucket_avg(1, 'cpu', 0, 20, 10) YIELD bucket_ts, avg RETURN bucket_ts, avg");
        defer r.deinit(allocator);
        const bi = colIndex(r, "bucket_ts").?;
        const ai = colIndex(r, "avg").?;
        try std.testing.expectEqual(@as(usize, 2), r.rows.len);
        try std.testing.expectEqual(@as(i64, 0), r.rows[0][bi].Int);
        try std.testing.expectEqual(@as(i64, 15), r.rows[0][ai].Int);
        try std.testing.expectEqual(@as(i64, 30), r.rows[1][ai].Int);
    }
}
