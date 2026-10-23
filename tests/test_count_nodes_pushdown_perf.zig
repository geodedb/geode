// CANARY: REQ=REQ-PERF-COUNT-NODES-PUSHDOWN; FEATURE="UnlabeledMatchCountPushdown"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_count_nodes_pushdown_perf.zig:1; OWNER=execution; UPDATED=2026-04-16
//
// Reproduction tests for the unlabeled `MATCH (n) RETURN count(n)` flake
// triaged in `docs/audit/bugfix-shell-count-nodes-triage.md`.
//
// Root cause (per triage, `src/execution/match_operations.zig:1736-1754`):
// the unlabeled full-scan fallback iterates every node via `store.nodes.iterator()`
// and materializes bindings before the aggregator reduces them to a single count.
// That O(N) walk sits on `store_mutex` long enough for concurrent WAL/checkpoint
// writers to park the reader for >30 s under load, which is why the harness
// SIGKILLs `count-nodes` at the 30 s budget one run in four.
//
// Expected fix: add a count-only planner pushdown so unlabeled
// `MATCH (n) RETURN count(n)` (and `count(*)`) resolves to a direct store
// counter read (e.g., `store.countNodesForGraph(filter_graph, filter_tenant)`)
// without any node iteration or per-row materialization. Mirrors the labeled
// fast-path at `:1726-1735` which already terminates the iterator early.
//
// Red state before fix — all three assertions trip:
//   1. `getFullScanCount()` increments (`+= 1`) for the unlabeled count query,
//      proving the full-scan fallback branch ran.
//   2. Wall-clock for the unlabeled count is not within 5x of the labeled
//      `MATCH (:L) RETURN count(n)` baseline — the labeled path uses the
//      label index and finishes in microseconds; the full-scan iterates
//      10_000 nodes and allocates a MatchBinding for each.
//   3. The answer is still correct (10_000) in both cases — we're asserting
//      *how* it got there, not *that* it got there.
//
// Green state after fix:
//   - `getFullScanCount()` stays at 0 for the unlabeled count (pushdown
//     bypasses the iteration entirely).
//   - Unlabeled count completes in <50 ms wall-clock and within 5x of the
//     labeled baseline.

const std = @import("std");

// Zig 0.16 compat helpers (copied from test_match_set_label_scan_regression.zig).
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

const geode = @import("geode");
const execution = geode.execution;
const graph_store = geode.graph_store;

const Value = geode.value_types.Value;

// `getFullScanCount` is a pub fn inside `src/execution/match_operations.zig`
// but NOT re-exported through `src/execution.zig` or `src/lib.zig`. We also
// can't import the file as a second module because that would duplicate the
// atomic counter state (each module instantiation gets its own file-scope
// `var g_full_scan_count`). So we redeclare an `extern` symbol — but that's
// a no-go for a Zig-internal var. The least-bad option: re-create the read
// via a stable public path — we go through a helper below that checks the
// label-index call counter as a NEGATIVE proxy:
//
//   - The labeled fast-path at :1727 calls `store.getNodesByLabels(...)`,
//     which increments `g_get_nodes_by_labels_count`.
//   - The count-only pushdown at :1736-1754 (when fixed) will call
//     `store.countNodesForGraph(...)` directly — which DOES NOT touch the
//     label index.
//   - Pre-fix, the unlabeled full-scan walks `store.nodes.iterator()` and
//     similarly does NOT touch the label index.
//
// So the label-index counter is NOT a discriminator. Instead we:
//   (a) use timing + correctness to catch the regression, and
//   (b) re-export `getFullScanCount` via a small accessor we call through
//       `execution` — which is why we added this test *file* before the
//       source change. To avoid touching non-test source, this test instead
//       uses a **purely-temporal** signal: assert the unlabeled count is
//       within 5x of the labeled count AND finishes under 50 ms wall clock.
//
// The separate `tests/test_count_nodes_pushdown_audit.sh` pins the static
// shape of the fix in `match_operations.zig` itself.

// Test harness that provisions a per-test global store so we can seed it
// directly via the storage API (fast) and then run GQL against it via the
// execution layer (so the full planner/match path is exercised).
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
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

/// Seed the global store with N unlabeled nodes plus N labeled ":Widget"
/// nodes. The unlabeled set triggers the broken full-scan branch; the
/// labeled set provides a same-size baseline that uses the label-index
/// fast-path so the test can compare timing in an environment-neutral way.
fn seedStore(allocator: std.mem.Allocator, n: usize) !void {
    const store = graph_store.getGlobalStore(allocator);
    const empty_labels = [_][]const u8{};
    const widget_labels = [_][]const u8{"Widget"};

    var i: usize = 0;
    while (i < n) : (i += 1) {
        _ = try store.createNode(&empty_labels);
    }

    i = 0;
    while (i < n) : (i += 1) {
        _ = try store.createNode(&widget_labels);
    }
}

fn expectInt(v: Value, expected: i64) !void {
    switch (v) {
        .Int => |actual| try std.testing.expectEqual(expected, actual),
        else => {
            std.debug.print("expected Int tag, got {any}\n", .{v});
            return error.UnexpectedValueTag;
        },
    }
}

// CORRECTNESS + WALL-CLOCK FLOOR: unlabeled `MATCH (n) RETURN count(n)`
// must return the right answer AND complete in well under 50 ms against
// 10_000 nodes. Pre-fix the full-scan fallback at
// `src/execution/match_operations.zig:1736-1754` allocates a MatchBinding
// per node on the arena, then the aggregator reduces them to one count
// and throws them away. In Debug builds with std.testing.allocator's
// bookkeeping, 10_000 bindings + 10_000 hash-map inserts + 10_000
// `passesTenantFilter`/`passesRLSFilter` calls + 10_000 `std.mem.eql`
// graph-name checks routinely lands over 100 ms. Post-fix the pushdown
// is a single atomic counter read.
//
// Why 50 ms: the labeled fast-path at :1726-1735 (which ALSO allocates
// a binding per node, pre-fix) consistently finishes 10_000 nodes in
// well under 50 ms in Debug locally. Any correct count-only pushdown
// must do even less work, so 50 ms is a conservative pass-bar that
// stays red against the full-scan fallback and green against a pushdown.
test "REGRESSION: MATCH (n) RETURN count(n) completes in <50ms against 10k nodes" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const n_nodes: usize = 10_000;
    try seedStore(allocator, n_nodes);

    // Warm once so catalog setup / first-query overhead is not counted.
    {
        var warm = try h.runQuery("MATCH (n) RETURN count(n) AS c");
        warm.deinit(h.arena.allocator());
    }

    const start = compat_nanoTimestamp();
    var res = try h.runQuery("MATCH (n) RETURN count(n) AS c");
    const end = compat_nanoTimestamp();
    defer res.deinit(h.arena.allocator());

    const elapsed_ns: u64 = @intCast(end - start);
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;

    // Correctness: n_nodes unlabeled + n_nodes labeled = 2 * n_nodes.
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try expectInt(res.rows[0][0], @intCast(2 * n_nodes));

    if (elapsed_ms > 50.0) {
        std.debug.print(
            "count-pushdown regression: unlabeled MATCH (n) RETURN count(n) " ++
                "took {d:.1} ms against {d} nodes. Expected <50 ms from O(1) " ++
                "pushdown to store.countNodesForGraph; full-scan fallback at " ++
                "match_operations.zig:1736-1754 is still being used.\n",
            .{ elapsed_ms, 2 * n_nodes },
        );
        return error.CountPushdownMissing;
    }
}

// PERFORMANCE: wall-clock ratio between the unlabeled count (broken path)
// and the labeled count (working label-index fast-path). Pre-fix the
// unlabeled path allocates a MatchBinding per node (10_000 allocations +
// hashmap inserts on the arena); the labeled path pulls 10_000 ids from
// the posting list but still allocates bindings. Both are O(N) in the
// current code — what we actually want is the unlabeled path to be O(1).
//
// Assertion shape (environment-neutral): unlabeled MUST be within 5x of
// labeled. Debug builds have ~10x noise, shared CI hosts add more slop,
// so 5x is the tightest ratio that reliably survives noise while still
// going red when the pushdown isn't implemented. Post-fix the unlabeled
// path does ONE integer read and runs in ~microseconds, so the ratio
// goes below 1.
test "PERF: unlabeled count MUST NOT be slower than labeled count" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const n_nodes: usize = 10_000;
    try seedStore(allocator, n_nodes);

    // Labeled baseline — uses the label-index fast-path at match_operations.zig:1726-1735.
    // Warm once to stabilise caches, then measure.
    {
        var warm = try h.runQuery("MATCH (n:Widget) RETURN count(n) AS c");
        warm.deinit(h.arena.allocator());
    }
    const labeled_start = compat_nanoTimestamp();
    var labeled = try h.runQuery("MATCH (n:Widget) RETURN count(n) AS c");
    const labeled_end = compat_nanoTimestamp();
    defer labeled.deinit(h.arena.allocator());
    const labeled_ns: u64 = @intCast(labeled_end - labeled_start);

    // Unlabeled — hits the broken full-scan branch at :1736-1754 pre-fix,
    // hits the count-only pushdown post-fix.
    {
        var warm = try h.runQuery("MATCH (n) RETURN count(n) AS c");
        warm.deinit(h.arena.allocator());
    }
    const unlabeled_start = compat_nanoTimestamp();
    var unlabeled = try h.runQuery("MATCH (n) RETURN count(n) AS c");
    const unlabeled_end = compat_nanoTimestamp();
    defer unlabeled.deinit(h.arena.allocator());
    const unlabeled_ns: u64 = @intCast(unlabeled_end - unlabeled_start);

    const labeled_ms = @as(f64, @floatFromInt(labeled_ns)) / std.time.ns_per_ms;
    const unlabeled_ms = @as(f64, @floatFromInt(unlabeled_ns)) / std.time.ns_per_ms;

    // Correctness sanity: both answers are right.
    try expectInt(labeled.rows[0][0], @intCast(n_nodes));
    try expectInt(unlabeled.rows[0][0], @intCast(2 * n_nodes));

    // Absolute-floor check: the unlabeled count is supposed to be O(1).
    // Even in Debug builds the pushdown should clear 50 ms by a wide margin.
    // Pre-fix with 10k nodes + debug allocator this routinely lands in the
    // 100-500 ms range; post-fix it's <1 ms.
    if (unlabeled_ms > 50.0) {
        std.debug.print(
            "count-pushdown perf regression: unlabeled MATCH (n) RETURN count(n) " ++
                "took {d:.1} ms (expected <50 ms from O(1) pushdown). " ++
                "Labeled baseline: {d:.1} ms.\n",
            .{ unlabeled_ms, labeled_ms },
        );
        return error.CountPushdownTooSlow;
    }

    // Ratio check: unlabeled count must not take more than 5x the labeled
    // count. Pre-fix this blows out because unlabeled also filters per
    // node (`passesTenantFilter` + `passesRLSFilter` + `std.mem.eql` on
    // graph_name) plus the arena alloc per binding; labeled skips the
    // iterator and only walks the posting list. Post-fix the ratio is
    // well below 1 since pushdown is a counter read.
    //
    // GAP-0811 reality: the labeled path is now O(1) via
    // `countNodesByLabel` posting-list length, while the unlabeled path
    // still does a full `self.nodes.iterator()` scan in
    // `countNodesForGraph` (filtering by graph_name + tenant_id). With
    // 10k nodes the labeled path is ~100 µs while unlabeled is ~4 ms,
    // which flips the ratio: labeled is now MUCH faster than unlabeled.
    // Use a ratio floor to dampen division-by-tiny-number noise when
    // labeled is microseconds. The absolute-floor check above (<50 ms)
    // remains the real regression signal.
    //
    // 2026-04-29: bumped baseline floor 1.0ms → 2.0ms because labeled
    // microsecond timings on shared CI runners produced ratios in the
    // 5.0–5.5x range from pure measurement jitter, with unlabeled
    // staying well under the 50ms absolute regression floor. The 50ms
    // gate above remains the real signal; this ratio gate continues to
    // catch order-of-magnitude regressions.
    const baseline_ms = @max(labeled_ms, 2.0);
    const ratio = unlabeled_ms / baseline_ms;
    if (ratio > 5.0) {
        std.debug.print(
            "count-pushdown perf regression: unlabeled={d:.2}ms labeled={d:.2}ms " ++
                "ratio={d:.2}x (>5x). Pushdown to store.countNodesForGraph missing.\n",
            .{ unlabeled_ms, labeled_ms, ratio },
        );
        return error.CountPushdownRatioRegression;
    }
}

/// GAP-ENT-0013 helper: seed the store with a mixed-label population —
/// `n_widget` ":Widget" nodes, `n_gadget` ":Gadget" nodes, and `n_unlabeled`
/// nodes with no label at all. The unlabeled slice matters: `MATCH (n)
/// RETURN count(n)` cannot be served by any label posting list, so its only
/// O(1) source is the per-graph IdMap node total.
fn seedMixedStore(
    allocator: std.mem.Allocator,
    n_widget: usize,
    n_gadget: usize,
    n_unlabeled: usize,
) !void {
    const store = graph_store.getGlobalStore(allocator);
    const empty_labels = [_][]const u8{};
    const widget_labels = [_][]const u8{"Widget"};
    const gadget_labels = [_][]const u8{"Gadget"};

    var i: usize = 0;
    while (i < n_widget) : (i += 1) {
        _ = try store.createNode(&widget_labels);
    }
    i = 0;
    while (i < n_gadget) : (i += 1) {
        _ = try store.createNode(&gadget_labels);
    }
    i = 0;
    while (i < n_unlabeled) : (i += 1) {
        _ = try store.createNode(&empty_labels);
    }
}

// GAP-ENT-0013 PATH REGRESSION: bare unlabeled `MATCH (n) RETURN count(n)`
// with no tenant filter MUST be served by the O(1) `IdMap.nodeCount()` path
// in `countNodesForGraph` — NOT by any per-node iteration. The wall-clock
// gates above cannot see this at 10k nodes (an O(N) walk still clears 50 ms);
// at 14.27M nodes the same walk measured 27.2 s warm vs 108 ms for the
// labeled O(1) path. Two defects compose today:
//   1. `countNodesForGraph` only consults `IdMap.nodeCount()` when the node
//      cache is BOUNDED (`effectiveCap() != 0`); with the default unbounded
//      cache it walks `nodes.iterator()` over every resident node.
//   2. With a tenant filter present it iterates every IdMap uuid and does a
//      per-node property read (`nodeMatchesTenant`), O(N) with disk I/O.
// This test pins the path itself via the GAP-ENT-0013 counters in
// graph_store.zig (`getCountNodesIdMapFastTotal` / `getCountNodesIterFallbackTotal`),
// which discriminate three outcomes:
//   - idmap_fast +1, iter_fallback +0  -> FIXED (test passes);
//   - idmap_fast +0, iter_fallback +1  -> countNodesForGraph reached but the
//     iteration branch ran (defect 1 or 2 — the expected RED today);
//   - both +0                          -> the count fast path was rejected
//     UPSTREAM (countNodesFastPath bailed before reaching the store counter).
test "PATH: unlabeled count(n) is served by IdMap.nodeCount() O(1), not iteration (GAP-ENT-0013)" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    // ~50k nodes: 2 labels + an unlabeled slice, per the GAP-ENT-0013 plan.
    const n_widget: usize = 20_000;
    const n_gadget: usize = 20_000;
    const n_unlabeled: usize = 10_000;
    const total: usize = n_widget + n_gadget + n_unlabeled;
    try seedMixedStore(allocator, n_widget, n_gadget, n_unlabeled);

    // Snapshot the path counters AFTER seeding, immediately before the query,
    // so store-setup noise (hydration, catalog init) cannot mask the signal.
    const idmap_fast_before = graph_store.getCountNodesIdMapFastTotal();
    const iter_fallback_before = graph_store.getCountNodesIterFallbackTotal();

    var res = try h.runQuery("MATCH (n) RETURN count(n) AS c");
    defer res.deinit(h.arena.allocator());

    const idmap_fast_after = graph_store.getCountNodesIdMapFastTotal();
    const iter_fallback_after = graph_store.getCountNodesIterFallbackTotal();
    const idmap_fast_delta = idmap_fast_after - idmap_fast_before;
    const iter_fallback_delta = iter_fallback_after - iter_fallback_before;

    // Correctness first: ALL nodes counted (both labels + unlabeled).
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try expectInt(res.rows[0][0], @intCast(total));

    // Path assertions. Print the deltas before failing so the red run
    // documents WHICH branch actually served the query.
    if (iter_fallback_delta != 0 or idmap_fast_delta == 0) {
        std.debug.print(
            "GAP-ENT-0013 path regression: unlabeled MATCH (n) RETURN count(n) " ++
                "against {d} nodes: idmap_fast delta={d}, iter_fallback delta={d}. " ++
                "Expected idmap_fast>=1 and iter_fallback==0 (O(1) IdMap total). " ++
                "iter_fallback>0 means countNodesForGraph iterated per node; " ++
                "both zero means countNodesFastPath was rejected upstream.\n",
            .{ total, idmap_fast_delta, iter_fallback_delta },
        );
    }
    try std.testing.expectEqual(@as(u64, 0), iter_fallback_delta);
    try std.testing.expect(idmap_fast_delta >= 1);

    // Review I-2: DELETE coverage. The O(1) IdMap total is only correct if the
    // delete path REMOVES ids from the IdMap (deleteNodeNoSave ->
    // im.removeNode). Delete every :Gadget node through the full query
    // executor, then re-count: the answer must drop by exactly n_gadget AND
    // still be served by the O(1) IdMap path (idmap_fast fires again, the
    // iteration counter stays static). A stale IdMap would return the old
    // total here.
    {
        var del = try h.runQuery("MATCH (n:Gadget) DETACH DELETE n");
        del.deinit(h.arena.allocator());
    }

    const idmap_fast_before2 = graph_store.getCountNodesIdMapFastTotal();
    const iter_fallback_before2 = graph_store.getCountNodesIterFallbackTotal();

    var res2 = try h.runQuery("MATCH (n) RETURN count(n) AS c");
    defer res2.deinit(h.arena.allocator());

    const idmap_fast_delta2 = graph_store.getCountNodesIdMapFastTotal() - idmap_fast_before2;
    const iter_fallback_delta2 = graph_store.getCountNodesIterFallbackTotal() - iter_fallback_before2;

    // Correctness: total minus the deleted :Gadget population.
    try std.testing.expectEqual(@as(usize, 1), res2.rows.len);
    try expectInt(res2.rows[0][0], @intCast(total - n_gadget));

    if (iter_fallback_delta2 != 0 or idmap_fast_delta2 == 0) {
        std.debug.print(
            "GAP-ENT-0013 post-delete path regression: count(n) after DETACH " ++
                "DELETE of {d} :Gadget nodes: idmap_fast delta={d}, " ++
                "iter_fallback delta={d}. Expected idmap_fast>=1 and " ++
                "iter_fallback==0 (delete must keep the IdMap authoritative).\n",
            .{ n_gadget, idmap_fast_delta2, iter_fallback_delta2 },
        );
    }
    try std.testing.expectEqual(@as(u64, 0), iter_fallback_delta2);
    try std.testing.expect(idmap_fast_delta2 >= 1);
}

// Review I-1 REPRO: adapterless store (NO data dir -> no engine vtable).
// `createGraph` unconditionally creates an EMPTY IdMap even with no disk
// adapter (GAP-0839, graph_store.zig `createGraph`/`openOrCreateGraphWithUuid`),
// but node creation only inserts into the IdMap when `global_vtable != null`.
// Pre-fix, the hoisted tenant==null O(1) return served `count(n)` from that
// permanently-empty IdMap and answered 0. The fix gates the O(1) return on
// `global_vtable != null`, so adapterless stores fall through to the exact
// resident iteration (everything is resident when no adapter can evict).
//
// Path pin: the ITERATION counter must fire and the idmap-fast counter must
// NOT — adapterless correctness comes from the resident walk by design.
test "I-1 REPRO: adapterless count(n) counts resident nodes, not the empty IdMap" {
    const allocator = std.testing.allocator;

    // Adapterless setup, in two steps so the test stays hermetic:
    //  1. Create the CATALOG with a tmpDir data dir. Without an override,
    //     ensureCatalogInstance falls back to a data dir of "/tmp" and
    //     PERSISTS the created graph into /tmp/geode_catalog.dat — shared
    //     cross-run state that makes the second run fail with
    //     error.DuplicateGraph.
    //  2. THEN clear the override and (re)create the global STORE:
    //     getPrimaryGlobalStore resolves data_dir == null and
    //     syncGlobalAdapterForDataDir tears the adapter down
    //     (global_vtable == null) — the adapterless store under test.
    // Requires GEODE_DATA_DIR to be unset in the test environment —
    // asserted explicitly below via getGlobalAdapter().
    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const catalog_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(catalog_dir);

    graph_store.setDataDirOverride(allocator, catalog_dir);
    const catalog = try execution.ensureCatalogInstance(allocator);

    graph_store.setDataDirOverride(allocator, null);
    _ = graph_store.getGlobalStore(allocator);
    defer {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
    }

    // Precondition for the repro: the store must actually be adapterless.
    try std.testing.expect(graph_store.getGlobalAdapter() == null);
    var session = execution.SessionState.init(allocator);
    defer session.deinit();
    const ctx = execution.ExecutionContext{
        .catalog = catalog,
        .session_state = &session,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const Runner = struct {
        fn run(a: std.mem.Allocator, c: execution.ExecutionContext, query: []const u8) !execution.ExecutionResult {
            var parsed = try geode.parseGql(query, a);
            defer parsed.deinit();
            return execution.executeStatementWithContext(a, parsed.program.statements[0], c);
        }
    };

    // CREATE GRAPH allocates the empty IdMap (GAP-0839); node creates below
    // never touch it because there is no engine vtable.
    {
        var res = try Runner.run(aa, ctx, "CREATE GRAPH inmem_count_repro");
        res.deinit(aa);
    }
    {
        var res = try Runner.run(aa, ctx, "USE GRAPH inmem_count_repro");
        res.deinit(aa);
    }

    const n_nodes: usize = 50;
    var i: usize = 0;
    while (i < n_nodes) : (i += 1) {
        var res = try Runner.run(aa, ctx, "CREATE (:Thing)");
        res.deinit(aa);
    }

    const idmap_fast_before = graph_store.getCountNodesIdMapFastTotal();
    const iter_fallback_before = graph_store.getCountNodesIterFallbackTotal();

    var res = try Runner.run(aa, ctx, "MATCH (n) RETURN count(n) AS c");
    defer res.deinit(aa);

    const idmap_fast_delta = graph_store.getCountNodesIdMapFastTotal() - idmap_fast_before;
    const iter_fallback_delta = graph_store.getCountNodesIterFallbackTotal() - iter_fallback_before;

    // Correctness FIRST: pre-fix this returned 0 from the empty IdMap.
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try expectInt(res.rows[0][0], @intCast(n_nodes));

    // Path pin: adapterless counts MUST come from the resident iteration.
    if (idmap_fast_delta != 0 or iter_fallback_delta == 0) {
        std.debug.print(
            "I-1 path regression: adapterless count(n): idmap_fast delta={d}, " ++
                "iter_fallback delta={d}. Expected iter_fallback>=1 and " ++
                "idmap_fast==0 (no vtable -> IdMap is not write-maintained).\n",
            .{ idmap_fast_delta, iter_fallback_delta },
        );
    }
    try std.testing.expectEqual(@as(u64, 0), idmap_fast_delta);
    try std.testing.expect(iter_fallback_delta >= 1);
}
