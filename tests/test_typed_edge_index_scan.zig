// GAP-ENT-0004 — typed-edge enumeration must NOT scan every node.
//
// With the bounded edge cache the resident `edge_type_index` posting list is
// no longer complete, so `getEdgesByType` derives type membership from the
// engine. The ORIGINAL derivation (`collectEdgesByTypeFromEngine`) walked
// EVERY node of the graph and expanded its outgoing adjacency
// (hydrate-on-miss) — O(nodes+edges) engine reads + cache thrash. At 14.27M
// nodes that is an effective hang for any legacy-executor typed-edge shape
// (concrete-tenant sessions, DELETE/SET-carrying matches, UNWIND/CALL/CTE
// statements with a typed rel and no node labels).
//
// The fix serves the enumeration from the ENGINE's per-shard edge_index
// (EdgeIndexMap: mmap base ⊕ overlay ⊖ tombstones, entries carry rel_type +
// inline public_id) — ONE O(total edges) sequential index scan, NO node
// iteration, NO adjacency hydration, and NO edge-body/property reads for
// tenantless callers.
//
// These tests pin:
//   1. CORRECTNESS — typed enumeration exact vs oracle across 2+ types under
//      a bounded edge cache (fresh store: pure-overlay edge_index).
//   2. PATH — the node walk did NOT run (typed_edge_node_walk_total /
//      typed_edge_node_walk_nodes_total stay 0 with an adapter present) while
//      the index-scan path did (typed_edge_index_scan_total moves).
//   3. EXECUTOR ROUTING — a CONCRETE-TENANT session (the planned runtime
//      demotes every MATCH-chain to the legacy executor for concrete tenant
//      scope) running `MATCH ()-[r:TYPE]->() RETURN count(r)` routes through
//      getEdgesByType and is served by the index scan, with exact
//      tenant-filtered results.
//   4. REOPEN — edges in the mmap BASE (persisted snapshot adopted after a
//      clean checkpoint+reopen) AND edges in the post-open OVERLAY are both
//      enumerated (forEachLive merged view).
//   5. SCALE SHAPE — 50k nodes / ~50k edges: the enumeration performs ZERO
//      node-body property reads and ZERO per-edge id-property fallbacks
//      (inline public ids), with a generous wall-clock backstop.
//
// CANARY: REQ=REQ-PERF-TYPED-EDGE-ENUM; FEATURE="TypedEdgeIndexScan"; ASPECT=NoNodeWalk; STATUS=TESTED; TEST=tests/test_typed_edge_index_scan.zig; OWNER=storage; UPDATED=2026-07-02

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const adapter_mod = geode.graph_storage_adapter;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn setBoundedCaps(edge_cap: [:0]const u8, adj_cap: [:0]const u8) !void {
    if (setenv("GEODE_EDGE_CACHE_ENTRIES", edge_cap.ptr, 1) != 0) return error.SetEnvFailed;
    if (setenv("GEODE_ADJ_CACHE_ENTRIES", adj_cap.ptr, 1) != 0) return error.SetEnvFailed;
    // Node cache unbounded so node residency never confounds the EDGE-path
    // assertions (suite convention, matches test_edge_engine_direct_bounded).
    if (setenv("GEODE_NODE_CACHE_ENTRIES", "0", 1) != 0) return error.SetEnvFailed;
}

fn clearCaps() void {
    _ = unsetenv("GEODE_EDGE_CACHE_ENTRIES");
    _ = unsetenv("GEODE_ADJ_CACHE_ENTRIES");
    _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
}

fn nowMonotonicNs() i128 {
    var ts: std.posix.timespec = undefined;
    const rc = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    if (rc != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

fn resetPathCounters() void {
    graph_store.typed_edge_index_scan_total.store(0, .monotonic);
    graph_store.typed_edge_node_walk_total.store(0, .monotonic);
    graph_store.typed_edge_node_walk_nodes_total.store(0, .monotonic);
}

/// Sorted-compare an enumeration result against an oracle id set (exact —
/// same length, same ids, no duplicates, no strays).
fn expectExactIdSet(allocator: std.mem.Allocator, got: []const u64, oracle: []const u64) !void {
    try testing.expectEqual(oracle.len, got.len);
    const got_sorted = try allocator.dupe(u64, got);
    defer allocator.free(got_sorted);
    const oracle_sorted = try allocator.dupe(u64, oracle);
    defer allocator.free(oracle_sorted);
    std.mem.sort(u64, got_sorted, {}, std.sort.asc(u64));
    std.mem.sort(u64, oracle_sorted, {}, std.sort.asc(u64));
    try testing.expectEqualSlices(u64, oracle_sorted, got_sorted);
}

fn assertServedByIndexScanNotWalk() !void {
    const walk = graph_store.typed_edge_node_walk_total.load(.monotonic);
    const walk_nodes = graph_store.typed_edge_node_walk_nodes_total.load(.monotonic);
    const scans = graph_store.typed_edge_index_scan_total.load(.monotonic);
    if (walk != 0 or walk_nodes != 0) {
        std.debug.print(
            "[typed-edge] FAIL: legacy node walk ran with an adapter present (walks={d}, nodes_visited={d}, index_scans={d})\n",
            .{ walk, walk_nodes, scans },
        );
    }
    try testing.expectEqual(@as(u64, 0), walk);
    try testing.expectEqual(@as(u64, 0), walk_nodes);
    try testing.expect(scans >= 1);
}

// ===================================================================
// Test 1 — correctness vs oracle across two types + path proof.
// ===================================================================

test "typed-edge enum: exact vs oracle across 2 types under bounded edge cache; served by engine index scan, node walk never runs" {
    try setBoundedCaps("128", "128");
    defer clearCaps();

    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(data_dir);

    const store = try graph_store.initGlobalStore(testing.allocator, data_dir);
    defer {
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
    }

    const PARENTS: usize = 300;
    const ACCEPTS: usize = 120;

    var parent_oracle = std.ArrayList(u64).empty;
    defer parent_oracle.deinit(testing.allocator);
    var accept_oracle = std.ArrayList(u64).empty;
    defer accept_oracle.deinit(testing.allocator);

    var labels = [_][]const u8{"Taxon"};
    var p: usize = 0;
    while (p < PARENTS) : (p += 1) {
        const a = try store.createNodeWithGraph(&labels, "default");
        const b = try store.createNodeWithGraph(&labels, "default");
        const eid = try store.createEdgeWithGraph(a, b, "PARENT_OF", "default");
        try parent_oracle.append(testing.allocator, eid);
    }
    var acc: usize = 0;
    while (acc < ACCEPTS) : (acc += 1) {
        const a = try store.createNodeWithGraph(&labels, "default");
        const b = try store.createNodeWithGraph(&labels, "default");
        const eid = try store.createEdgeWithGraph(a, b, "ACCEPTED_AS", "default");
        try accept_oracle.append(testing.allocator, eid);
    }

    // Bounded edge cache genuinely active (else getEdgesByType would serve
    // from the resident posting list and prove nothing).
    try testing.expect(store.edges.effectiveCap() != 0);

    resetPathCounters();

    const parent_ids = store.getEdgesByType(testing.allocator, "PARENT_OF", null, "default");
    defer if (parent_ids.len > 0) testing.allocator.free(parent_ids);
    try expectExactIdSet(testing.allocator, parent_ids, parent_oracle.items);

    const accept_ids = store.getEdgesByType(testing.allocator, "ACCEPTED_AS", null, "default");
    defer if (accept_ids.len > 0) testing.allocator.free(accept_ids);
    try expectExactIdSet(testing.allocator, accept_ids, accept_oracle.items);

    // Unseen type: empty (label id never registered).
    const none_ids = store.getEdgesByType(testing.allocator, "NO_SUCH_TYPE", null, "default");
    defer if (none_ids.len > 0) testing.allocator.free(none_ids);
    try testing.expectEqual(@as(usize, 0), none_ids.len);

    // PATH: engine index scan served all three calls; the node walk NEVER ran.
    try assertServedByIndexScanNotWalk();
}

// ===================================================================
// Test 2 — executor routing: concrete-tenant session (legacy executor)
// `MATCH ()-[r:TYPE]->() RETURN count(r)` served by the index scan with
// exact tenant filtering.
// ===================================================================

test "typed-edge enum: concrete-tenant + multi-chain executor shapes route through the index scan with exact tenant filter" {
    try setBoundedCaps("64", "64");
    defer clearCaps();

    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(data_dir);

    const store = try graph_store.initGlobalStore(testing.allocator, data_dir);
    defer {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
    }

    var labels = [_][]const u8{"Doc"};
    const ALPHA: usize = 25;
    const DEFAULTS: usize = 5;

    var i: usize = 0;
    while (i < ALPHA) : (i += 1) {
        const a = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_alpha");
        const b = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_alpha");
        _ = try store.createEdgeWithGraphAndTenant(a, b, "LINKED", "default", "tenant_alpha");
    }
    i = 0;
    while (i < DEFAULTS) : (i += 1) {
        const a = try store.createNodeWithGraph(&labels, "default");
        const b = try store.createNodeWithGraph(&labels, "default");
        _ = try store.createEdgeWithGraph(a, b, "LINKED", "default");
    }

    try testing.expect(store.edges.effectiveCap() != 0);

    resetPathCounters();

    // Storage-level: tenant-filtered enumeration is exact.
    {
        const alpha_ids = store.getEdgesByType(testing.allocator, "LINKED", "tenant_alpha", "default");
        defer if (alpha_ids.len > 0) testing.allocator.free(alpha_ids);
        try testing.expectEqual(ALPHA, alpha_ids.len);
        for (alpha_ids) |eid| {
            const e = store.getEdgePtrHydrated(eid) orelse return error.EdgeBodyLost;
            try testing.expectEqualStrings("tenant_alpha", e.tenant_id);
        }
    }

    // Executor-level correctness under a CONCRETE tenant scope (the planned
    // runtime demotes every MATCH-chain plan to the legacy executor for a
    // concrete tenant): single-chain `RETURN r` is tenant-exact. (This shape
    // is served by the legacy per-node hop traversal, not getEdgesByType —
    // no counter assertion here.)
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        var parsed = try geode.parse(aa, "MATCH ()-[r:LINKED]->() RETURN r", .{});
        defer parsed.deinit();
        const catalog = try execution.ensureCatalogInstance(testing.allocator);
        const ctx = execution.ExecutionContext{ .catalog = catalog, .tenant_id = "tenant_alpha" };
        var res = try execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
        defer res.deinit(aa);
        try testing.expectEqual(ALPHA, res.rows.len);
    }

    // Executor-level ROUTING proof: a MULTI-chain query whose relationship
    // chain has a typed rel and NO node labels routes through
    // executeMultiChainRelationshipMatch's typed branch → getEdgesByType —
    // the exact call this gap is about (multi-chain typed-edge shapes reach
    // it even tenantless; concrete-tenant sessions reach it for everything).
    const walks_before_executor = graph_store.typed_edge_node_walk_total.load(.monotonic);
    const scans_before_executor = graph_store.typed_edge_index_scan_total.load(.monotonic);
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        var anchor_labels = [_][]const u8{"Anchor"};
        const anchor = try store.createNodeWithGraphAndTenant(&anchor_labels, "default", "tenant_alpha");
        _ = anchor;
        // Relationship chain FIRST: the typed no-label branch handles the
        // first chain's hop (subsequent chains join against its bindings).
        var parsed = try geode.parse(aa, "MATCH ()-[r:LINKED]->(), (a:Anchor) RETURN r, a", .{});
        defer parsed.deinit();
        const catalog = try execution.ensureCatalogInstance(testing.allocator);
        const ctx = execution.ExecutionContext{ .catalog = catalog, .tenant_id = "tenant_alpha" };
        var res = try execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
        defer res.deinit(aa);
        // Cartesian of 1 anchor × ALPHA tenant-visible LINKED edges.
        try testing.expectEqual(ALPHA, res.rows.len);
    }
    // The executor route itself must have gone through the typed-edge
    // enumeration (scan counter moved) without the walk.
    try testing.expect(graph_store.typed_edge_index_scan_total.load(.monotonic) > scans_before_executor);
    try testing.expectEqual(walks_before_executor, graph_store.typed_edge_node_walk_total.load(.monotonic));

    // PATH: both the direct call and the executor route were index-scan
    // served; the every-node walk never ran.
    try assertServedByIndexScanNotWalk();
}

// ===================================================================
// Test 3 — reopen: mmap BASE records + post-open OVERLAY records are
// both enumerated (merged view), node walk never runs.
// ===================================================================

test "typed-edge enum: reopen serves mmap-base edges AND post-open overlay edges (merged view)" {
    try setBoundedCaps("64", "64");
    defer clearCaps();

    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(data_dir);
    defer graph_store.setDataDirOverride(testing.allocator, null);

    var rel_a_oracle = std.ArrayList(u64).empty;
    defer rel_a_oracle.deinit(testing.allocator);
    var rel_b_oracle = std.ArrayList(u64).empty;
    defer rel_b_oracle.deinit(testing.allocator);

    var labels = [_][]const u8{"N"};

    // ---- Boot 1: 60 REL_A edges, checkpoint, clean close. These become the
    // persisted edge_index snapshot (the mmap BASE on reopen). ----
    {
        const store = try graph_store.initGlobalStore(testing.allocator, data_dir);
        defer graph_store.deinitGlobalStore();
        const adapter = graph_store.getGlobalAdapter().?;

        var i: usize = 0;
        while (i < 60) : (i += 1) {
            const a = try store.createNodeWithGraph(&labels, "default");
            const b = try store.createNodeWithGraph(&labels, "default");
            const eid = try store.createEdgeWithGraph(a, b, "REL_A", "default");
            try rel_a_oracle.append(testing.allocator, eid);
        }
        try adapter.checkpointAll();
    }

    // ---- Boot 2: reopen, hydrate, add 20 MORE REL_A + 10 REL_B (overlay). ----
    {
        const store = try graph_store.initGlobalStore(testing.allocator, data_dir);
        defer graph_store.deinitGlobalStore();

        try store.loadFromFile();
        store.ensureGraphHydrated("default");

        var i: usize = 0;
        while (i < 20) : (i += 1) {
            const a = try store.createNodeWithGraph(&labels, "default");
            const b = try store.createNodeWithGraph(&labels, "default");
            const eid = try store.createEdgeWithGraph(a, b, "REL_A", "default");
            try rel_a_oracle.append(testing.allocator, eid);
        }
        i = 0;
        while (i < 10) : (i += 1) {
            const a = try store.createNodeWithGraph(&labels, "default");
            const b = try store.createNodeWithGraph(&labels, "default");
            const eid = try store.createEdgeWithGraph(a, b, "REL_B", "default");
            try rel_b_oracle.append(testing.allocator, eid);
        }

        // Diagnostic: report whether the engine adopted an mmap base for the
        // edge_index (clean-counter gated adoption; the merged-view assertions
        // below hold either way — base+overlay or pure-resident rebuild).
        {
            const adapter = graph_store.getGlobalAdapter().?;
            if (adapter.engines.get("default")) |mg| {
                var with_base: usize = 0;
                for (mg.engine.shards) |shard| {
                    if (shard.edge_index.base != null) with_base += 1;
                }
                std.debug.print("[typed-edge reopen] shards with mmap edge_index base: {d}/{d}\n", .{ with_base, mg.engine.shards.len });
            }
        }

        try testing.expect(store.edges.effectiveCap() != 0);
        resetPathCounters();

        const rel_a_ids = store.getEdgesByType(testing.allocator, "REL_A", null, "default");
        defer if (rel_a_ids.len > 0) testing.allocator.free(rel_a_ids);
        try expectExactIdSet(testing.allocator, rel_a_ids, rel_a_oracle.items);

        const rel_b_ids = store.getEdgesByType(testing.allocator, "REL_B", null, "default");
        defer if (rel_b_ids.len > 0) testing.allocator.free(rel_b_ids);
        try expectExactIdSet(testing.allocator, rel_b_ids, rel_b_oracle.items);

        try assertServedByIndexScanNotWalk();
    }
}

// ===================================================================
// Test 4 — scale shape: 50k nodes / ~50k chained edges. The enumeration
// must not read node bodies (zero engine node-property reads), must not
// take the per-edge id-property fallback (inline v2 ids), and must not
// run the node walk. Generous wall-clock backstop.
// ===================================================================

test "typed-edge enum: 50k-node/50k-edge chain enumerates via the index scan with zero node-body reads" {
    try setBoundedCaps("256", "256");
    defer clearCaps();

    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(data_dir);

    const store = try graph_store.initGlobalStore(testing.allocator, data_dir);
    defer {
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
    }

    const K: usize = 50_000; // nodes; K-1 chained edges

    var labels = [_][]const u8{"Taxon"};
    var prev = try store.createNodeWithGraph(&labels, "default");
    var edge_count: usize = 0;
    var i: usize = 1;
    while (i < K) : (i += 1) {
        const next = try store.createNodeWithGraph(&labels, "default");
        _ = try store.createEdgeWithGraph(prev, next, "PARENT_OF", "default");
        prev = next;
        edge_count += 1;
    }

    try testing.expect(store.edges.effectiveCap() != 0);

    resetPathCounters();
    adapter_mod.resetLookupCounters();
    graph_store.edge_id_property_fallback_reads.store(0, .monotonic);

    const start_ns = nowMonotonicNs();
    const ids = store.getEdgesByType(testing.allocator, "PARENT_OF", null, "default");
    defer if (ids.len > 0) testing.allocator.free(ids);
    const end_ns = nowMonotonicNs();
    const elapsed_ns: u64 = if (end_ns > start_ns) @intCast(end_ns - start_ns) else 0;

    try testing.expectEqual(edge_count, ids.len);

    // PATH: index scan, never the walk.
    try assertServedByIndexScanNotWalk();

    // NO node bodies: zero engine-direct node property reads during the
    // enumeration (the index entries carry everything needed).
    const node_reads = adapter_mod.getNodePropertyEngineReads();
    if (node_reads != 0) {
        std.debug.print("[typed-edge scale] FAIL: {d} engine node-property reads during typed enumeration\n", .{node_reads});
    }
    try testing.expectEqual(@as(u64, 0), node_reads);

    // NO per-edge id-property fallback: fresh store, every edge carries the
    // inline v2 public id.
    try testing.expectEqual(@as(u64, 0), graph_store.edge_id_property_fallback_reads.load(.monotonic));

    // Generous wall-clock backstop (Debug builds): a sequential ~50k-record
    // index scan is milliseconds; the every-node walk with a 256-entry
    // adjacency cache hydrates ~50k adjacency lists + ~50k edge bodies from
    // the engine. 10s leaves ~2 orders of magnitude of margin for CI noise.
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
    std.debug.print("[typed-edge scale] enumerated {d} edges in {d} ms\n", .{ ids.len, elapsed_ms });
    try testing.expect(elapsed_ms < 10_000);
}
