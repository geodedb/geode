// GAP-0902 concurrency CRASH regression: analytical reads (string/numeric
// ORDER BY top-K, DISTINCT, multi-aggregate, WHERE-count) under a SMALL node
// cache cap must NOT crash and must NOT corrupt.
//
// Triage: the prior bounded-cache top-K read the order key via the CACHE
// (`store.nodes.get` resident-only + `getNodeProperty` hydrate-on-miss). The
// hydrate-on-miss path MUTATES the node cache (getOrPut + maybe evict) on the
// reader thread. Under several concurrent lock-free `getPtr` readers that drove
// an AutoHashMap rehash mid-read → process abort (the documented prior crash).
// The GAP-0902 fix reads the order key + tenant ENGINE-DIRECT
// (`adapter.getNodeProperty` / `adapter.getNodesByLabelCapped`), which never
// touches the cache map, so the analytical readers hold NO cache pointer and
// are crash-safe under concurrent reader churn even when most of the graph is
// evicted (every read hits the engine-direct path). The engine-direct DISTINCT
// / multi-aggregate / WHERE-count paths (`planned_read_runtime`, which
// materializes owned node copies straight from the engine) are likewise
// cache-pointer-free.
//
// TEST 1 (readers-only churn): 8 readers continuously run all analytical shapes
// against a bounded cache where most nodes are evicted. This is the "concurrent
// reader churn" the prior cache-mutation crash needed; the engine-direct fix
// must complete it with no crash and no corrupt ORDER BY page.
//
// TEST 2 (reads + light ingest): mirrors the proven contention model of
// `test_scan_ingest_race.zig` — one writer CREATEs while readers run the string
// ORDER BY top-K (the GAP-0902 fix). Validates the engine-direct order-key read
// coexists with concurrent ingest + eviction.
//
// NOTE (pre-existing, out of scope): a heavy reads+ingest stress can trip a
// PRE-EXISTING buffer-pool eviction race in the vendored graph_storage package
// (`buffer_pool.evictFrame`/`flushFrame` releases the pool mutex during a dirty
// page flush, letting a concurrent `pin` alias the evicting frame; the later
// `unpin` then hits `assert(pin_count > 0)`). That abort reproduces on the
// pristine bound-node-mirror HEAD with this work reverted (e.g. via the writer's
// `putPropertyTxn`->`logPage`->`unpin`), so it is independent of GAP-0902 and is
// reported separately. Test 2 keeps ingest light to stay within the regime the
// existing scan/ingest race test already exercises cleanly.
//
// CANARY: REQ=REQ-CONCURRENCY-BOUNDED-ANALYTICAL-0902; FEATURE="BoundedAnalyticalReadSafety"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0902_concurrent_analytical.zig; OWNER=storage; UPDATED=2026-06-22

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const GRAPH = graph_store.DEFAULT_GRAPH_NAME;

const Shared = struct {
    allocator: std.mem.Allocator,
    ctx: execution.ExecutionContext,
    store: *graph_store.GraphStore,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    writes_done: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    reads_done: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    err_seen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn strOf(v: anytype) []const u8 {
    return switch (v) {
        .Str => |s| s,
        .Text => |s| s,
        else => "",
    };
}

// Parse with `geode.parse` so ORDER BY over `n.<key>` property access parses,
// then execute. Transient executor errors are tolerated; a CRASH is not.
fn runAnalytical(sh: *Shared, aa: std.mem.Allocator, src: []const u8) void {
    var parsed = geode.parse(aa, src, .{}) catch return;
    defer parsed.deinit();
    var r = execution.executeStatementWithContext(aa, parsed.program.statements[0], sh.ctx) catch return;
    r.deinit(aa);
}

// Run the string ORDER BY top-K and verify the page is non-empty + sorted
// (catches a torn/corrupt read as well as a crash).
fn runStringOrderByChecked(sh: *Shared, aa: std.mem.Allocator) void {
    var parsed = geode.parse(aa, "MATCH (n:Taxon) RETURN n.source_id ORDER BY n.source_id ASC LIMIT 10", .{}) catch {
        sh.err_seen.store(true, .release);
        return;
    };
    defer parsed.deinit();
    if (execution.executeStatementWithContext(aa, parsed.program.statements[0], sh.ctx)) |res_const| {
        var r = res_const;
        defer r.deinit(aa);
        if (r.rows.len >= 2) {
            var prev = strOf(r.rows[0][0]);
            for (r.rows[1..]) |row| {
                const cur = strOf(row[0]);
                if (std.mem.order(u8, prev, cur) == .gt) {
                    sh.err_seen.store(true, .release); // out-of-order → corruption
                    return;
                }
                prev = cur;
            }
        }
    } else |_| {}
}

fn allShapesReaderThread(sh: *Shared) void {
    var n: usize = 0;
    while (n < 200 and !sh.err_seen.load(.acquire)) : (n += 1) {
        var arena = std.heap.ArenaAllocator.init(sh.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        runStringOrderByChecked(sh, aa); // 1. string ORDER BY top-K (engine-direct)
        runAnalytical(sh, aa, "MATCH (n:Taxon) RETURN n.ordinal ORDER BY n.ordinal DESC LIMIT 10"); // 2. numeric top-K
        runAnalytical(sh, aa, "MATCH (n:Taxon) RETURN min(n.ordinal) AS lo, max(n.ordinal) AS hi"); // 3. multi-aggregate
        runAnalytical(sh, aa, "MATCH (n:Taxon) RETURN sum(n.ordinal) AS s"); // 4. single-aggregate (engine-direct)
        runAnalytical(sh, aa, "MATCH (n:Taxon) WHERE n.ordinal < 100 RETURN count(n) AS c"); // 5. WHERE-count
        runAnalytical(sh, aa, "MATCH (n:Taxon) RETURN DISTINCT n.source_id"); // 6. DISTINCT
        _ = sh.reads_done.fetchAdd(1, .monotonic);
    }
}

fn writerThread(sh: *Shared) void {
    var i: usize = 1_000_000;
    while (!sh.stop.load(.acquire)) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(sh.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        const q = std.fmt.allocPrint(aa, "CREATE (:Taxon {{source_id: 'col:{d:0>9}', ordinal: {d}}})", .{ i, i }) catch {
            sh.err_seen.store(true, .release);
            return;
        };
        var parsed = geode.parse(aa, q, .{}) catch {
            sh.err_seen.store(true, .release);
            return;
        };
        defer parsed.deinit();
        var r = execution.executeStatementWithContext(aa, parsed.program.statements[0], sh.ctx) catch continue;
        r.deinit(aa);
        _ = sh.writes_done.fetchAdd(1, .monotonic);
    }
}

// Light-ingest reader: string ORDER BY top-K only (the GAP-0902 fix), so the
// reader cadence matches `test_scan_ingest_race`'s single-prepare-per-iteration.
fn orderByReaderThread(sh: *Shared) void {
    var n: usize = 0;
    while (n < 600 and !sh.err_seen.load(.acquire)) : (n += 1) {
        var arena = std.heap.ArenaAllocator.init(sh.allocator);
        defer arena.deinit();
        runStringOrderByChecked(sh, arena.allocator());
        _ = sh.reads_done.fetchAdd(1, .monotonic);
    }
    sh.stop.store(true, .release);
}

const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    store: *graph_store.GraphStore,
    ctx: execution.ExecutionContext,

    fn init(allocator: std.mem.Allocator, seed_n: usize) !Harness {
        if (setenv("GEODE_NODE_CACHE_ENTRIES", "256", 1) != 0) return error.SetEnvFailed;
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        const catalog = try execution.ensureCatalogInstance(allocator);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        var i: usize = 0;
        while (i < seed_n) : (i += 1) {
            const q = try std.fmt.allocPrint(aa, "CREATE (:Taxon {{source_id: 'col:{d:0>9}', ordinal: {d}}})", .{ i, i });
            var parsed = try geode.parse(aa, q, .{});
            defer parsed.deinit();
            var r = try execution.executeStatementWithContext(aa, parsed.program.statements[0], .{ .catalog = catalog });
            r.deinit(aa);
        }
        return .{ .allocator = allocator, .tmp = tmp, .data_dir = data_dir, .store = store, .ctx = .{ .catalog = catalog } };
    }

    fn deinit(self: *Harness) void {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
        _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
    }
};

// ===================================================================
// TEST 1 — concurrent reader churn (the cache-mutation crash repro).
// ===================================================================
test "GAP-0902: concurrent analytical reader churn does not crash (bounded cache)" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, 4000);
    defer h.deinit();

    // Most of the graph is evicted — every analytical read hits engine-direct.
    try testing.expect(h.store.nodes.residentCount() < 4000 / 2);

    var sh = Shared{ .allocator = allocator, .ctx = h.ctx, .store = h.store };
    const reader_count = 8;
    var readers: [reader_count]std.Thread = undefined;
    for (&readers) |*r| r.* = try std.Thread.spawn(.{}, allShapesReaderThread, .{&sh});
    for (&readers) |r| r.join();

    // No crash, no corrupt ORDER BY page, real work happened.
    try testing.expect(!sh.err_seen.load(.acquire));
    try testing.expect(sh.reads_done.load(.monotonic) > 0);
    // Cache stayed bounded throughout (engine-direct reads never grew it).
    try testing.expect(h.store.nodes.residentCount() <= 256);
}

// ===================================================================
// TEST 2 — string ORDER BY top-K coexists with concurrent light ingest.
// ===================================================================
test "GAP-0902: string ORDER BY top-K + concurrent ingest does not crash" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, 2000);
    defer h.deinit();

    var sh = Shared{ .allocator = allocator, .ctx = h.ctx, .store = h.store };
    const reader_count = 4;
    var writer = try std.Thread.spawn(.{}, writerThread, .{&sh});
    var readers: [reader_count]std.Thread = undefined;
    for (&readers) |*r| r.* = try std.Thread.spawn(.{}, orderByReaderThread, .{&sh});
    for (&readers) |r| r.join();
    sh.stop.store(true, .release);
    writer.join();

    try testing.expect(!sh.err_seen.load(.acquire));
    try testing.expect(sh.reads_done.load(.monotonic) > 0);
    try testing.expect(sh.writes_done.load(.monotonic) > 0);
}
