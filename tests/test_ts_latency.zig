// CANARY: REQ=REQ-GQL-TS-STORAGE-PERF-001; FEATURE="TimeseriesStorageBackend"; ASPECT=RangeLatencyGate; STATUS=TESTED; TEST=tests/test_ts_latency.zig; OWNER=storage; UPDATED=2026-05-31
//
// CI-aware latency gate for the timeseries-storage-backed `geode.ts.*` path.
//
// Geode's timeseries surface is backed by the `timeseries_storage` library
// (re-exported through src/timeseries/timeseries.zig) and driven over the GQL
// `CALL <proc>(args)` surface by src/execution/ts_dispatch.zig:
//   - CALL geode.ts.insert(device_id, metric, ts, value)   → YIELD inserted
//   - CALL geode.ts.range(device_id, metric, start, end)   → YIELD ts, value
//
// This test exercises the real store + real parser + real executor (no mocks),
// mirroring the FTS latency gate (tests/test_fts_latency.zig) for the timeseries
// path and the ts_ingest_roundtrip.zig harness idiom: the dispatcher resolves
// the timeseries Store via `eval.getTimeseriesStoreForGraph(null)` → the global
// `g_timeseries_store`, so the test installs an in-process Store via
// `eval.setGlobalTimeseriesStore` (the server-boot wiring path) — the graph
// store is never used for geode.ts.* and is freed after each call.
//
// It asserts BOTH correctness (the expected rows come back, ascending by ts) and
// — outside CI — a strict latency upper bound on the range query. The latency
// budget is generous (single-core, range scan over the series). The CI skip is
// applied for the same reason as the other perf-gate tests: the local pre-push
// runs many shards >> cores, which makes a wall-clock budget meaningless there.
// The correctness assertions always run.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const eval = geode.eval;
const ts = geode.timeseries;
const Store = ts.Store;

// Zig 0.16 compat helper (copied from test_fts_latency.zig).
fn compat_nanoTimestamp() i128 {
    var t: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &t);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &t);
    }
    return @as(i128, t.sec) * 1_000_000_000 + @as(i128, t.nsec);
}

/// Drive a single CALL geode.ts.* statement through the full execution path
/// (parse → executeStatementWithContext → ts_dispatch). Mirrors the
/// ts_ingest_roundtrip.zig harness: the ExecutionContext needs a catalog
/// singleton, and executeCallProcedure lazily creates the global graph store
/// (graph_store.getGlobalStore) before reaching the geode.ts.* branch even
/// though our procedures resolve the timeseries Store via the separate global
/// pointer, so the graph store is freed after each call to keep the
/// leak-checking test allocator green.
fn runQuery(allocator: std.mem.Allocator, query: []const u8) !execution.ExecutionResult {
    var parsed = try geode.parseGql(query, allocator);
    defer parsed.deinit();

    const catalog = try execution.ensureCatalogInstance(allocator);
    defer execution.cleanupCatalogInstance();
    defer geode.graph_store.deinitGlobalStore();

    const ctx = execution.ExecutionContext{ .catalog = catalog };
    return execution.executeStatementWithContext(allocator, parsed.program.statements[0], ctx);
}

/// Find a column index by name (case-sensitive — the dispatcher emits canonical
/// lowercase column names).
fn colIndex(res: execution.ExecutionResult, name: []const u8) ?usize {
    for (res.columns, 0..) |c, i| {
        if (std.mem.eql(u8, c, name)) return i;
    }
    return null;
}

test "TS latency: CALL geode.ts.range returns seeded points within budget" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    eval.setGlobalTimeseriesStore(&store);
    defer eval.setGlobalTimeseriesStore(null);

    // 1) Seed a known series (device 1, metric 'temp') with three points
    //    inserted out of ts order. The store returns them ascending by ts.
    {
        var r = try runQuery(allocator, "CALL geode.ts.insert(1, 'temp', 100, 72)");
        r.deinit(allocator);
    }
    {
        var r = try runQuery(allocator, "CALL geode.ts.insert(1, 'temp', 90, 70)");
        r.deinit(allocator);
    }
    {
        var r = try runQuery(allocator, "CALL geode.ts.insert(1, 'temp', 110, 73)");
        r.deinit(allocator);
    }

    // Warm up (caches / first-allocation amortization). Untimed.
    {
        var warm = try runQuery(allocator, "CALL geode.ts.range(1, 'temp', 90, 110)");
        warm.deinit(allocator);
    }

    // Timed: a single CALL geode.ts.range over the full [90, 110] window.
    const t0 = compat_nanoTimestamp();
    var res = try runQuery(allocator, "CALL geode.ts.range(1, 'temp', 90, 110)");
    defer res.deinit(allocator);
    const elapsed_ns = compat_nanoTimestamp() - t0;

    // Correctness ALWAYS runs: all three points come back, ascending by ts,
    // as (ts, value) rows.
    const ti = colIndex(res, "ts").?;
    const vi = colIndex(res, "value").?;
    try testing.expectEqual(@as(usize, 3), res.rows.len);
    try testing.expectEqual(@as(i64, 90), res.rows[0][ti].Int);
    try testing.expectEqual(@as(i64, 70), res.rows[0][vi].Int);
    try testing.expectEqual(@as(i64, 100), res.rows[1][ti].Int);
    try testing.expectEqual(@as(i64, 72), res.rows[1][vi].Int);
    try testing.expectEqual(@as(i64, 110), res.rows[2][ti].Int);
    try testing.expectEqual(@as(i64, 73), res.rows[2][vi].Int);

    // A window that excludes every point returns zero rows (sanity on the
    // range path, not just "always returns everything").
    {
        var none = try runQuery(allocator, "CALL geode.ts.range(1, 'temp', 200, 300)");
        defer none.deinit(allocator);
        try testing.expectEqual(@as(usize, 0), none.rows.len);
    }

    // Latency smoke. Budget is deliberately generous for a single-core box
    // (the range scan walks the series). Skipped under CI/oversubscription for
    // the same reason as the other perf-gate tests; the correctness assertions
    // above always run.
    if (std.c.getenv("CI") == null) {
        try testing.expect(elapsed_ns < 50_000_000); // 50 ms
    }
}
