// CANARY: REQ=REQ-PERF-QPS-H3P5; FEATURE="OrderedIndexAutoBuild"; ASPECT=FreshStoreOrderBy; STATUS=TESTED; TEST=tests/test_ordered_index_autobuild.zig; OWNER=performance; UPDATED=2026-07-07
//
// GAP-0064 FIX C (ORDER BY on a fresh store): the value-ORDERED index
// (createOrderedIndex / orderedScan) is only ever built by an explicit
// `CREATE INDEX`, so a from-dump / freshly-ingested store has NONE — and
// `MATCH (n:L) RETURN n.k ORDER BY n.k LIMIT m` falls back to the full-scan
// top-K heap (6.7 s at 1M, times out at 14.27M) even though the planner
// `orderedScanFastPath` is fully wired.
//
// FIX C makes the ordered index MATERIALIZE without a manual CREATE INDEX:
//   * The planner, on an ORDER-BY-<prop>-LIMIT query whose ordered index is not
//     yet registered, kicks off a ONE-TIME, uncancellable, deduped BACKGROUND
//     build (register + rebuild + persist via a full checkpoint) and serves THIS
//     query from the heap (correct, slower). Subsequent ORDER BY on that prop is
//     served from the value-ordered index (`orderedScanFastPath`, hits==1).
//   * The build is not a per-query cost: it happens exactly once per (label,key);
//     a re-trigger while in flight (or after it is registered) is a no-op.
//   * gs persists the ordered snapshot on the (checkpoint_epoch, covered_lsn)
//     Path-B contract (GAP-0050), so the NEXT reopen RELOADS it (O(snapshot))
//     and ORDER BY is index-served immediately — no rebuild.
//
// This file pins all three: auto-build-on-query, build-once (dedup), and
// persist-then-reload across a real adapter reopen. Real store, real parser,
// real executor, tmpDir — no mocks.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const gs = @import("graph_storage");

const execution = geode.execution;
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;
const StorageAdapter = adapter_mod.StorageAdapter;
const PropertyValue = graph_store.PropertyValue;

fn testConfig() gs.GraphConfig {
    return .{
        .page_size = 4096,
        .buffer_pool_pages = 64,
    };
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

// Poll until the background ordered-index build worker has FULLY completed
// (build + persist), or fail after a generous timeout.
fn waitForOrderedBuildCompletion(min_completions: u64) !void {
    var waited_ms: u64 = 0;
    while (adapter_mod.getOrderedBuildCompletionsForTesting() < min_completions) {
        if (waited_ms > 60_000) return error.OrderedBuildTimedOut;
        sleepMs(5);
        waited_ms += 5;
    }
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parse(aa, query, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

// Seed N nodes :T with a STRING key k = zero-padded permutation of [0,N). Width
// 5 => lexical order == numeric order; (i*97)%N scrambles insertion vs value.
fn seedT(h: *Harness, n: usize) !void {
    const aa = h.arena.allocator();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v: usize = (i * 97) % n;
        const q = try std.fmt.allocPrint(aa, "CREATE (:T {{k: '{d:0>5}'}})", .{v});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }
}

test "FIX C: ORDER BY on a fresh store auto-builds the ordered index, then serves it (hits==1), build-once" {
    // Opt IN to the ORDER-BY auto-build (suppressed by default under test).
    adapter_mod.setOrderedAutobuildDisabledForTest(false);
    defer adapter_mod.setOrderedAutobuildDisabledForTest(null);

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const n: usize = 300;
    try seedT(&h, n);

    const adapter = graph_store.getGlobalAdapter().?;
    const g = graph_store.DEFAULT_GRAPH_NAME;

    // Precondition: a from-dump-like store has NO ordered index for (T,k).
    try testing.expect(!adapter.isOrderedIndexRegistered(g, "T", "k"));

    adapter_mod.resetOrderedIndexBuildsForTesting();
    adapter_mod.resetOrderedBuildCompletionsForTesting();

    // First ORDER BY: no ordered index yet -> the planner kicks off the ONE-TIME
    // background build and serves THIS query from the heap (correct, hits==0).
    execution.resetOrderedScanFastPathHits();
    {
        var res = try h.runQuery("MATCH (n:T) RETURN n.k ORDER BY n.k ASC LIMIT 10");
        defer res.deinit(h.arena.allocator());
        try testing.expectEqual(@as(u64, 0), execution.getOrderedScanFastPathHits());
        // Heap fallback still correct.
        try testing.expectEqual(@as(usize, 10), res.rows.len);
        var buf: [8]u8 = undefined;
        for (res.rows, 0..) |row, idx| {
            const want = try std.fmt.bufPrint(&buf, "{d:0>5}", .{idx});
            try testing.expectEqualStrings(want, row[0].Str);
        }
    }

    // Wait for the background build + persist to complete.
    try waitForOrderedBuildCompletion(1);

    // The ordered index is now registered, eligible, and fresh on every shard.
    try testing.expect(adapter.isOrderedIndexRegistered(g, "T", "k"));
    try testing.expect(adapter.isOrderedIndexEligible(g, "T", "k"));
    try testing.expect(adapter.isOrderedIndexFresh(g, "T", "k"));
    try testing.expectEqual(@as(u64, 1), adapter_mod.getOrderedIndexBuildsForTesting());

    // Second ORDER BY: served from the value-ordered index (hits==1), correct order.
    execution.resetOrderedScanFastPathHits();
    {
        var res = try h.runQuery("MATCH (n:T) RETURN n.k ORDER BY n.k ASC LIMIT 10");
        defer res.deinit(h.arena.allocator());
        try testing.expectEqual(@as(u64, 1), execution.getOrderedScanFastPathHits());
        try testing.expectEqual(@as(usize, 10), res.rows.len);
        var buf: [8]u8 = undefined;
        for (res.rows, 0..) |row, idx| {
            const want = try std.fmt.bufPrint(&buf, "{d:0>5}", .{idx});
            try testing.expectEqualStrings(want, row[0].Str);
        }
    }

    // DESC also served now (same registered index).
    execution.resetOrderedScanFastPathHits();
    {
        var res = try h.runQuery("MATCH (n:T) RETURN n.k ORDER BY n.k DESC LIMIT 5");
        defer res.deinit(h.arena.allocator());
        try testing.expectEqual(@as(u64, 1), execution.getOrderedScanFastPathHits());
        try testing.expectEqual(@as(usize, 5), res.rows.len);
        var buf: [8]u8 = undefined;
        for (res.rows, 0..) |row, idx| {
            const want = try std.fmt.bufPrint(&buf, "{d:0>5}", .{n - 1 - idx});
            try testing.expectEqualStrings(want, row[0].Str);
        }
    }

    // Build-once / not-a-per-query-cost: repeated ORDER BY never rebuilds.
    {
        var j: usize = 0;
        while (j < 5) : (j += 1) {
            var res = try h.runQuery("MATCH (n:T) RETURN n.k ORDER BY n.k ASC LIMIT 3");
            res.deinit(h.arena.allocator());
        }
    }
    try testing.expectEqual(@as(u64, 1), adapter_mod.getOrderedIndexBuildsForTesting());
}

// The canonical real-world shape is `RETURN n.k AS a ORDER BY a LIMIT m` — the
// ORDER BY references a RETURN ALIAS, not `n.k` directly. FIX C resolves that
// alias (one hop) so it both TRIGGERS the auto-build and, once built, is served
// from the ordered index. (Pre-fix this bare-Ident ORDER BY silently fell to the
// full-sort path.)
test "FIX C: aliased ORDER BY (RETURN n.k AS a ORDER BY a) auto-builds and is served" {
    adapter_mod.setOrderedAutobuildDisabledForTest(false);
    defer adapter_mod.setOrderedAutobuildDisabledForTest(null);

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const n: usize = 300;
    try seedT(&h, n);

    const adapter = graph_store.getGlobalAdapter().?;
    const g = graph_store.DEFAULT_GRAPH_NAME;
    try testing.expect(!adapter.isOrderedIndexRegistered(g, "T", "k"));

    adapter_mod.resetOrderedBuildCompletionsForTesting();

    // First aliased ORDER BY: triggers the build, served from the heap (hits==0),
    // and correct.
    execution.resetOrderedScanFastPathHits();
    {
        var res = try h.runQuery("MATCH (n:T) RETURN n.k AS a ORDER BY a ASC LIMIT 10");
        defer res.deinit(h.arena.allocator());
        try testing.expectEqual(@as(u64, 0), execution.getOrderedScanFastPathHits());
        try testing.expectEqual(@as(usize, 10), res.rows.len);
        var buf: [8]u8 = undefined;
        for (res.rows, 0..) |row, idx| {
            const want = try std.fmt.bufPrint(&buf, "{d:0>5}", .{idx});
            try testing.expectEqualStrings(want, row[0].Str);
        }
    }

    try waitForOrderedBuildCompletion(1);
    try testing.expect(adapter.isOrderedIndexRegistered(g, "T", "k"));

    // Second aliased ORDER BY: served from the value-ordered index (hits==1).
    execution.resetOrderedScanFastPathHits();
    {
        var res = try h.runQuery("MATCH (n:T) RETURN n.k AS a ORDER BY a ASC LIMIT 10");
        defer res.deinit(h.arena.allocator());
        try testing.expectEqual(@as(u64, 1), execution.getOrderedScanFastPathHits());
        try testing.expectEqual(@as(usize, 10), res.rows.len);
        var buf: [8]u8 = undefined;
        for (res.rows, 0..) |row, idx| {
            const want = try std.fmt.bufPrint(&buf, "{d:0>5}", .{idx});
            try testing.expectEqualStrings(want, row[0].Str);
        }
    }
}

// Result parity: the auto-built ordered-index path must return byte-identical
// rows to the heap scan+sort for the same query. Each label's VERY FIRST ORDER
// BY is guaranteed heap-served (the index is not registered yet — that query
// only kicks off the build); after the build the same query is index-served.
// We capture the heap baseline (first query) and the index result (second query,
// post-build) for the SAME label+direction and assert they are byte-identical.
// A distinct label per direction gives each direction its own heap baseline.
fn seedLabel(h: *Harness, comptime lbl: []const u8, n: usize) !void {
    const aa = h.arena.allocator();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v: usize = (i * 97) % n;
        const q = try std.fmt.allocPrint(aa, "CREATE (:" ++ lbl ++ " {{k: '{d:0>5}'}})", .{v});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }
}

// Capture the string-column rows of a query into an owned list (arena-backed).
fn captureRows(h: *Harness, res: *execution.ExecutionResult) ![][]const u8 {
    const aa = h.arena.allocator();
    var out = try aa.alloc([]const u8, res.rows.len);
    for (res.rows, 0..) |row, idx| out[idx] = try aa.dupe(u8, row[0].Str);
    return out;
}

test "FIX C: auto-built ordered path == heap path (byte-for-byte parity, ASC and DESC)" {
    // Opt IN to the ORDER-BY auto-build (suppressed by default under test).
    adapter_mod.setOrderedAutobuildDisabledForTest(false);
    defer adapter_mod.setOrderedAutobuildDisabledForTest(null);

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const aa = h.arena.allocator();
    const n: usize = 256;
    try seedLabel(&h, "Pa", n); // ASC parity label
    try seedLabel(&h, "Pd", n); // DESC parity label

    const adapter = graph_store.getGlobalAdapter().?;
    const g = graph_store.DEFAULT_GRAPH_NAME;

    // ---- ASC parity on :Pa ----
    adapter_mod.resetOrderedBuildCompletionsForTesting();
    execution.resetOrderedScanFastPathHits();
    var heap_asc = try h.runQuery("MATCH (n:Pa) RETURN n.k ORDER BY n.k ASC LIMIT 25");
    const heap_asc_rows = try captureRows(&h, &heap_asc);
    heap_asc.deinit(aa);
    try testing.expectEqual(@as(u64, 0), execution.getOrderedScanFastPathHits()); // heap baseline

    try waitForOrderedBuildCompletion(1);
    try testing.expect(adapter.isOrderedIndexRegistered(g, "Pa", "k"));

    execution.resetOrderedScanFastPathHits();
    var idx_asc = try h.runQuery("MATCH (n:Pa) RETURN n.k ORDER BY n.k ASC LIMIT 25");
    defer idx_asc.deinit(aa);
    try testing.expectEqual(@as(u64, 1), execution.getOrderedScanFastPathHits()); // index-served
    try testing.expectEqual(heap_asc_rows.len, idx_asc.rows.len);
    for (idx_asc.rows, heap_asc_rows) |row_i, row_h| {
        try testing.expectEqualStrings(row_h, row_i[0].Str);
    }

    // ---- DESC parity on :Pd ----
    adapter_mod.resetOrderedBuildCompletionsForTesting();
    execution.resetOrderedScanFastPathHits();
    var heap_desc = try h.runQuery("MATCH (n:Pd) RETURN n.k ORDER BY n.k DESC LIMIT 25");
    const heap_desc_rows = try captureRows(&h, &heap_desc);
    heap_desc.deinit(aa);
    try testing.expectEqual(@as(u64, 0), execution.getOrderedScanFastPathHits()); // heap baseline

    try waitForOrderedBuildCompletion(1);
    try testing.expect(adapter.isOrderedIndexRegistered(g, "Pd", "k"));

    execution.resetOrderedScanFastPathHits();
    var idx_desc = try h.runQuery("MATCH (n:Pd) RETURN n.k ORDER BY n.k DESC LIMIT 25");
    defer idx_desc.deinit(aa);
    try testing.expectEqual(@as(u64, 1), execution.getOrderedScanFastPathHits()); // index-served
    try testing.expectEqual(heap_desc_rows.len, idx_desc.rows.len);
    for (idx_desc.rows, heap_desc_rows) |row_i, row_h| {
        try testing.expectEqualStrings(row_h, row_i[0].Str);
    }
}

// Persist + reload across a real adapter reopen (the gs GAP-0050 contract driven
// end-to-end through geode). Session 1 auto-builds + full-checkpoints; Session 2
// reopens and the ordered index is RELOADED from the snapshot (registered
// immediately, geode never rebuilds), so orderedScan is served at once.
test "FIX C: ordered index persists and RELOADS on the next reopen (no rebuild)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph = "reload_graph";
    const label = "T";
    const n: usize = 256;

    // Expected ASC order of the string keys "00000".."00255".
    // ---- Session 1: seed + auto-build (sync) + full checkpoint + close. ----
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const v: usize = (i * 97) % n;
            const node_id = try adapter.createNode(graph, &[_][]const u8{label});
            var buf: [8]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d:0>5}", .{v});
            try adapter.setNodeProperty(graph, node_id, "k", .{ .String = s });
        }

        try testing.expect(!adapter.isOrderedIndexRegistered(graph, label, "k"));

        adapter_mod.resetOrderedIndexBuildsForTesting();
        // Synchronous variant of the auto-build (deterministic; same core as the
        // async worker's register+rebuild).
        try adapter.buildOrderedIndexSyncForTesting(graph, label, "k");
        try testing.expectEqual(@as(u64, 1), adapter_mod.getOrderedIndexBuildsForTesting());
        try testing.expect(adapter.isOrderedIndexRegistered(graph, label, "k"));

        // FULL checkpoint persists the ordered snapshot stamped
        // (checkpoint_epoch, last_checkpoint_lsn) so a clean reopen reloads it.
        try adapter.checkpointAll();
    }

    // ---- Session 2: reopen; the ordered index RELOADS (no geode rebuild). ----
    adapter_mod.resetOrderedIndexBuildsForTesting();
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        // Open the graph WITHOUT any CREATE INDEX / build call.
        _ = try adapter.getOrCreateGraph(graph);

        // The ordered index is registered immediately from the reloaded snapshot,
        // and geode ran NO ordered rebuild of its own.
        try testing.expect(adapter.isOrderedIndexRegistered(graph, label, "k"));
        try testing.expect(adapter.isOrderedIndexEligible(graph, label, "k"));
        try testing.expect(adapter.isOrderedIndexFresh(graph, label, "k"));
        try testing.expectEqual(@as(u64, 0), adapter_mod.getOrderedIndexBuildsForTesting());

        // orderedScan is served and correctly ordered (ASC top-10 == 0..9).
        const ids = try adapter.orderedScan(graph, label, "k", .asc, 10, allocator);
        defer allocator.free(ids);
        try testing.expectEqual(@as(usize, 10), ids.len);
        var prev: ?[]u8 = null;
        for (ids) |node_id| {
            const pv = (try adapter.getNodeProperty(graph, node_id, "k", allocator)).?;
            defer switch (pv) {
                .string => |sv| allocator.free(sv),
                else => {},
            };
            const cur = switch (pv) {
                .string => |sv| sv,
                else => return error.UnexpectedType,
            };
            if (prev) |p| {
                try testing.expect(std.mem.order(u8, p, cur) == .lt);
                allocator.free(p);
            }
            prev = try allocator.dupe(u8, cur);
        }
        if (prev) |p| allocator.free(p);
    }
}

// GAP-0064 INTEGRATION (ordered double-build race — the analog of the exact-index
// CRITICAL). The ORDER-BY auto-build's per-shard ordered rebuild
// (`adapter.createOrderedIndex` → gs `rebuildOrderedIndex`) and the FULL
// checkpoint's OWN ordered rebuild (gs `engine_persist.checkpointEx` →
// `rebuildOrderedIndex`, gated only on `ordered_property_index.count() > 0`)
// both `clearTrees()` + rescan the SAME per-shard ordered tree. Pre-integration
// the build took ONLY `shard_locks[i]` (no `rwlock`) while the checkpoint holds
// `mg.rwlock` EXCLUSIVE with no shard lock → DISJOINT locks → concurrent
// double-build / torn B-tree. The integration fix brings `createOrderedIndex`
// under `mg.rwlock` SHARED (per shard) so the checkpoint's EXCLUSIVE hold
// mutually excludes it.
//
// This test drives the build concurrently with a tight FULL-checkpoint loop on
// the SAME graph and asserts: no crash/corruption, the index ends registered +
// fresh, and `orderedScan` returns a correct global sort. Run under the thread
// sanitizer (`zig build test-ordered-index-autobuild-tsan`) it flags the data
// race pre-fix and is clean post-fix.
const ConcurrentCtx = struct {
    adapter: *StorageAdapter,
    graph: []const u8,
    label: []const u8,
    key: []const u8,
    iters: usize,

    fn buildLoop(ctx: *ConcurrentCtx) void {
        var i: usize = 0;
        while (i < ctx.iters) : (i += 1) {
            // Each call re-registers (idempotent) + rebuilds the ordered tree —
            // the exact work the background worker's `ensureOrderedIndexForKey`
            // runs. Best-effort (a transient error must not fail the harness).
            ctx.adapter.createOrderedIndex(ctx.graph, ctx.label, ctx.key) catch {};
        }
    }

    fn checkpointLoop(ctx: *ConcurrentCtx) void {
        // FULL checkpoints (each rebuilds the registered ordered index in gs),
        // a fixed count interleaved with the builder so the two ordered-rebuild
        // paths overlap on the SAME tree. Bounded (no unbounded loop) so the test
        // duration is deterministic and its race window is the whole run.
        var i: usize = 0;
        while (i < ctx.iters) : (i += 1) {
            ctx.adapter.checkpointAll() catch {};
        }
    }
};

test "FIX C integration: concurrent ordered-index build || FULL checkpoint — no race, correct order" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const graph = "cc_graph";
    const label = "T";
    const n: usize = 1000; // gcd(97,1000)=1 => (i*97)%n is a permutation of 0..n-1

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v: usize = (i * 97) % n;
        const node_id = try adapter.createNode(graph, &[_][]const u8{label});
        var buf: [8]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d:0>5}", .{v});
        try adapter.setNodeProperty(graph, node_id, "k", .{ .String = s });
    }

    // Register the ordered index once up front so the concurrent FULL checkpoints
    // ALSO rebuild it (count()>0) — this is what makes the two rebuild paths
    // overlap on the SAME tree (the race under test).
    try adapter.createOrderedIndex(graph, label, "k");
    try testing.expect(adapter.isOrderedIndexRegistered(graph, label, "k"));

    var ctx = ConcurrentCtx{
        .adapter = adapter,
        .graph = graph,
        .label = label,
        .key = "k",
        .iters = 30,
    };

    const t_build = try std.Thread.spawn(.{}, ConcurrentCtx.buildLoop, .{&ctx});
    const t_ckpt = try std.Thread.spawn(.{}, ConcurrentCtx.checkpointLoop, .{&ctx});
    t_build.join();
    t_ckpt.join();

    // Post-condition: no corruption. The index is registered + fresh on every
    // shard, and orderedScan yields a strictly-increasing global sort of the
    // n distinct string keys "00000".."0(n-1)".
    try testing.expect(adapter.isOrderedIndexRegistered(graph, label, "k"));
    try testing.expect(adapter.isOrderedIndexFresh(graph, label, "k"));

    const ids = try adapter.orderedScan(graph, label, "k", .asc, n, allocator);
    defer allocator.free(ids);
    try testing.expectEqual(@as(usize, n), ids.len);

    var prev: ?[]u8 = null;
    for (ids) |node_id| {
        const pv = (try adapter.getNodeProperty(graph, node_id, "k", allocator)).?;
        defer switch (pv) {
            .string => |sv| allocator.free(sv),
            else => {},
        };
        const cur = switch (pv) {
            .string => |sv| sv,
            else => return error.UnexpectedType,
        };
        if (prev) |p| {
            try testing.expect(std.mem.order(u8, p, cur) == .lt);
            allocator.free(p);
        }
        prev = try allocator.dupe(u8, cur);
    }
    if (prev) |p| allocator.free(p);
}
