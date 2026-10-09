// GAP-0891 regression suite — native-tenant write tagging and edge reads.
//
// These tests assert the CORRECT behavior and FAIL on the pre-fix code; they
// are the red phase of the fix. They drive the SAME production write entry
// points the server uses (no mocks). The original triage repro asserted the
// BROKEN behavior (count(n)==1, count(r)==0); these invert it.
//
// Root causes pinned here (file:line as of cef1f8ca):
//
//   RC-1 (dominant): the write-side tenant tag is resolved from
//     `fle_integration.getCurrentTenantId()` — a PER-THREAD map defaulting to
//     "default" (fle_integration.zig:125-129). QUIC handler threads call
//     `setCurrentTenantId(t_DEMO)`, but bulk-MERGE / group-commit writes run on
//     SHARD-WORKER threads (group_commit.zig:540-718) that never do, so every
//     bulk-written node/edge is tagged "default" for a t_DEMO request. The
//     exact-match read filter (passesTenantFilter / passesTenantFilterEdge,
//     match_operations.zig:138-151) is CORRECT — the rows just carry the wrong
//     tag. The authoritative resolver already exists:
//     `fle_integration.tenantPreferringActiveContext()`.
//
//   RC-2: restart hydration (`loadOneGraphFromAdapter`) hardcodes
//     DEFAULT_TENANT_ID for every node (graph_store.zig:6074) and edge (:6186),
//     so tenant tags are not durable across restart (the storage adapter has no
//     INTERNAL_TENANT_ID property key — it does not round-trip tenant_id today).
//
//   RC-3: internal-id create paths hardcode DEFAULT_TENANT_ID:
//     createNodeWithIdInternal (graph_store.zig:2306) and
//     createEdgeWithIdInternal (:4469).
//
//   Defense-in-depth (SUPERSEDED by SONNY-2693): edge visibility was ALSO
//     derived from endpoint visibility, so a legacy edge mis-tagged "default"
//     between two t_DEMO nodes stayed visible to t_DEMO. That bridge also
//     showed t_DEMO an edge tagged for ANOTHER tenant between its own nodes,
//     with its properties, so it is gone: an edge is visible only when its own
//     tag AND both endpoints are (`tenant_visibility.edgeTraversable`), and
//     `CALL geode.tenant.backfill_edge_tags()` re-tags the legacy edges. The
//     test below pins both halves.
//
// SKELETON seams added to production so these tests compile against the layer
// the fixer will change (each currently delegates to the broken path):
//   * graph_store.GraphStore.createNodeForRequestTenant  (RC-1 node seam)
//   * graph_store.GraphStore.createEdgeForRequestTenant  (RC-1 edge seam)

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;
const fle = geode.fle_integration;

const T_DEMO = "t_DEMO";
const GRAPH = "caast_data";

// Worker seed function — runs on a SPAWNED thread to model a group-commit shard
// worker. It deliberately does NOT call `setCurrentTenantId`, so its per-thread
// tenant map is empty (getCurrentTenantId() == "default"). It receives the
// request tenant captured on the HANDLER thread and routes every write through
// the explicit request-tenant seams the fixer will thread the ApplyOp tenant
// through. Results/errors are written through out-pointers so the joiner can
// assert deterministically (no sleeps).
fn workerSeed(
    store: *graph_store.GraphStore,
    eng_id: u64,
    request_tenant: []const u8,
    asset_ids: *[6]u64,
    edge_ids: *[6]u64,
    err_out: *?anyerror,
) void {
    const asset_labels = [_][]const u8{"Asset"};
    for (asset_ids) |*aid| {
        aid.* = store.createNodeForRequestTenant(&asset_labels, GRAPH, request_tenant) catch |e| {
            err_out.* = e;
            return;
        };
    }
    for (asset_ids.*, 0..) |aid, i| {
        edge_ids[i] = store.createEdgeForRequestTenant(eng_id, aid, "HAS_ASSET", GRAPH, request_tenant) catch |e| {
            err_out.* = e;
            return;
        };
    }
}

// RC-1: end-to-end native-tenant scenario at the store level.
// Seeds 1 handler-thread node + 6 worker-path nodes + 6 worker-path edges under
// t_DEMO and asserts every row is tagged t_DEMO and visible to a t_DEMO reader.
// Pre-fix: worker rows are tagged "default" -> count(n)==1, count(r)==0 (RED).
test "GAP-0891 RC-1: worker-path node and edge writes tag the request tenant" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    try store.createGraph(GRAPH);

    // ---- (1) HANDLER-THREAD write: per-thread tenant is set to t_DEMO ----
    // Mirrors the request thread setting the FLE tenant before a serial CREATE.
    fle.setCurrentTenantId(T_DEMO);
    const eng_labels = [_][]const u8{"Engagement"};
    const eng_id = try store.createNodeWithGraph(&eng_labels, GRAPH);
    // Capture the request tenant the way submit() would, then leave the handler
    // thread's view in place; the WORKER runs on its own thread with no tenant.
    const request_tenant = fle.getCurrentTenantId();
    try testing.expectEqualStrings(T_DEMO, request_tenant);
    fle.clearCurrentThreadState();

    // ---- (2) WORKER-THREAD writes: spawned thread, NO per-thread tenant ----
    var asset_ids: [6]u64 = undefined;
    var edge_ids: [6]u64 = undefined;
    var worker_err: ?anyerror = null;
    const worker = try std.Thread.spawn(.{}, workerSeed, .{
        &store, eng_id, request_tenant, &asset_ids, &edge_ids, &worker_err,
    });
    worker.join(); // deterministic join before any read — no concurrent access.
    if (worker_err) |e| return e;

    // ---- Storage tenant tags ----
    const eng_node = store.nodes.get(eng_id) orelse return error.NodeNotFound;
    // Handler-thread node is correctly tagged today; must stay correct.
    try testing.expectEqualStrings(T_DEMO, eng_node.tenant_id);

    // Every worker-path asset node must carry the request tenant.
    for (asset_ids) |aid| {
        const n = store.nodes.get(aid) orelse return error.NodeNotFound;
        try testing.expectEqualStrings(T_DEMO, n.tenant_id);
    }

    // Every worker-path edge must carry the request tenant.
    for (edge_ids) |eid| {
        const e = store.edges.get(eid) orelse return error.EdgeNotFound;
        try testing.expectEqualStrings(T_DEMO, e.tenant_id);
    }

    // ---- Read the way the native-tenant reader does: exact filter t_DEMO ----
    // countNodesForGraph(graph, tenant) is the bare-MATCH count fast path
    // (match_operations.zig). Expect all 7 application nodes (1 + 6).
    try testing.expectEqual(@as(usize, 7), store.countNodesForGraph(GRAPH, T_DEMO));

    // Edge visibility under the same exact-match filter; expect all 6 edges.
    var visible_edges: usize = 0;
    var eit = store.edges.iterator();
    while (eit.next()) |entry| {
        const e = entry.value_ptr;
        if (!std.mem.eql(u8, e.graph_name, GRAPH)) continue;
        if (std.mem.eql(u8, e.tenant_id, T_DEMO)) visible_edges += 1;
    }
    try testing.expectEqual(@as(usize, 6), visible_edges);
}

// RC-3: internal-id create paths (replication / WAL-replay / reload entries)
// must honor the active tenant, not hardcode "default".
// Pre-fix: createNodeWithIdInternal / createEdgeWithIdInternal force
// DEFAULT_TENANT_ID (graph_store.zig:2306, :4469) -> tags "default" (RED).
test "GAP-0891 RC-3: internal-id create paths honor the active tenant" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    try store.createGraph(GRAPH);

    // On the handler thread with the right tenant in effect.
    fle.setCurrentTenantId(T_DEMO);
    defer fle.clearCurrentThreadState();

    const asset_labels = [_][]const u8{"Asset"};
    try store.createNodeWithId(101, &asset_labels, GRAPH);
    try store.createNodeWithId(102, &asset_labels, GRAPH);
    try store.createEdgeWithId(9001, 101, 102, "HAS_ASSET", GRAPH);

    const n = store.nodes.get(101) orelse return error.NodeNotFound;
    const e = store.edges.get(9001) orelse return error.EdgeNotFound;

    // DESIRED: tagged t_DEMO because the active tenant is t_DEMO.
    try testing.expectEqualStrings(T_DEMO, n.tenant_id);
    try testing.expectEqualStrings(T_DEMO, e.tenant_id);
}

// RC-2: restart hydration must preserve tenant tags across an adapter-backed
// reload. Seeds t_DEMO-tagged data on the global (engine-backed) store,
// checkpoints, clears all per-thread state (so the reload cannot cheat off the
// thread map), reloads from the adapter, and asserts the tags survive.
// Pre-fix: loadOneGraphFromAdapter rebuilds every node/edge with
// DEFAULT_TENANT_ID (graph_store.zig:6074, :6186) AND the adapter has no
// tenant_id property to round-trip -> tags "default" (RED).
//
// SONNY-2689: since Phase 1b (a31800da, 7ae4bc0a) a reload only REGISTERS each
// graph for lazy hydration, and nothing is resident until the first read or
// write of the graph runs the `ensureGraphHydrated` chokepoint. `nodes.get` and
// `edges.get` read the resident cache only, without hydrating, so this test
// failed with NodeNotFoundAfterReload although the tags were durable. It now
// reaches the reloaded rows the way every read path does.
test "GAP-0891 RC-2: restart hydration preserves tenant tags" {
    const allocator = testing.allocator;

    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(dir_path);

    // Registered after the directory's cleanup, so it runs first: the store's
    // final persist still finds its directory.
    defer graph_store.deinitGlobalStore();

    const store = try graph_store.initGlobalStore(allocator, dir_path);

    // Handler-thread tenant in effect while we write (and persist) the data.
    fle.setCurrentTenantId(T_DEMO);
    const asset_labels = [_][]const u8{"Asset"};
    const a1 = try store.createNodeWithGraph(&asset_labels, GRAPH);
    const a2 = try store.createNodeWithGraph(&asset_labels, GRAPH);
    const edge_id = try store.createEdgeWithGraph(a1, a2, "HAS_ASSET", GRAPH);
    // Pre-fix and post-fix sanity: the in-memory tag is t_DEMO before reload.
    try testing.expectEqualStrings(T_DEMO, (store.nodes.get(a1) orelse return error.NodeNotFound).tenant_id);

    // Drop ALL per-thread state so the reload path can only recover the tenant
    // from durable storage — never from a stale thread-local fallback.
    fle.clearCurrentThreadState();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    try adapter.checkpointAll();

    // Reload from the adapter: clears the in-memory cache and registers the
    // graph for lazy hydration.
    try store.loadFromFile();

    // What a t_DEMO reader counts after the reload. It is the first read of
    // the graph, so it hydrates it; the explicit chokepoint call below keeps
    // the resident reads that follow independent of how the count is served.
    try testing.expectEqual(@as(usize, 2), store.countNodesForGraph(GRAPH, T_DEMO));
    store.ensureGraphHydrated(GRAPH);

    const reloaded_node = store.nodes.get(a1) orelse return error.NodeNotFoundAfterReload;
    const reloaded_edge = store.edges.get(edge_id) orelse return error.EdgeNotFoundAfterReload;

    // DESIRED: durable tenant tags survive restart.
    try testing.expectEqualStrings(T_DEMO, reloaded_node.tenant_id);
    try testing.expectEqualStrings(T_DEMO, reloaded_edge.tenant_id);
}

// SONNY-2689: the same tags across a real clean restart. `deinitGlobalStore`
// writes the IdMap snapshot, so the reopened store resolves an id without
// hydrating the graph, and a by-id read rebuilds the node or the edge alone
// from the engine (the node cache's `materializeNodeFromEngine`, the edge
// cache's hydrate hook). Each of those recovers the tenant on its own, apart
// from the full-graph build the test above goes through.
test "GAP-0891 RC-2: a clean restart keeps tenant tags on by-id reads" {
    const allocator = testing.allocator;

    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(dir_path);

    defer graph_store.deinitGlobalStore();

    var a1: u64 = undefined;
    var edge_id: u64 = undefined;
    {
        const store = try graph_store.initGlobalStore(allocator, dir_path);
        fle.setCurrentTenantId(T_DEMO);
        defer fle.clearCurrentThreadState();
        const asset_labels = [_][]const u8{"Asset"};
        a1 = try store.createNodeWithGraph(&asset_labels, GRAPH);
        const a2 = try store.createNodeWithGraph(&asset_labels, GRAPH);
        edge_id = try store.createEdgeWithGraph(a1, a2, "HAS_ASSET", GRAPH);
    }
    // Clean shutdown, then reopen: no per-thread tenant is in effect.
    graph_store.deinitGlobalStore();
    graph_store.resetLazyHydrateCounters();
    const store = try graph_store.initGlobalStore(allocator, dir_path);
    // The reopen took the snapshot route this test is about.
    try testing.expect(graph_store.idMapFromSnapshotCount() >= 1);

    const node = store.getNodePtrHydrated(a1) orelse return error.NodeNotFoundAfterRestart;
    try testing.expectEqualStrings(T_DEMO, node.tenant_id);
    const edge = store.getEdgeHydrated(edge_id) orelse return error.EdgeNotFoundAfterRestart;
    try testing.expectEqualStrings(T_DEMO, edge.tenant_id);
    try testing.expectEqual(@as(usize, 2), store.countNodesForGraph(GRAPH, T_DEMO));
}

// SONNY-2693 (supersedes the GAP-0891 defense-in-depth bridge): an edge whose
// BOTH endpoints are t_DEMO but which itself carries a legacy "default" tag is
// HIDDEN from a t_DEMO read — a "default" edge gets no endpoint-derived
// exception, exactly like a "default" node — until the backfill re-tags it to
// its endpoints' tenant. Then it is visible, and a second run changes nothing.
test "GAP-0891 / SONNY-2693: a legacy default-tagged edge between t_DEMO nodes is hidden until backfilled" {
    const allocator = testing.allocator;
    const tenant_visibility = geode.execution.tenant_visibility;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    try store.createGraph(GRAPH);

    const asset_labels = [_][]const u8{"Asset"};
    // Both endpoints correctly tagged t_DEMO.
    const a1 = try store.createNodeWithGraphAndTenant(&asset_labels, GRAPH, T_DEMO);
    const a2 = try store.createNodeWithGraphAndTenant(&asset_labels, GRAPH, T_DEMO);

    // The edge itself carries a legacy "default" tag (the kind a worker thread
    // would have mis-written before the RC-1 fix, or pre-existing data).
    const legacy_edge_id = try store.createEdgeWithGraphAndTenant(
        a1,
        a2,
        "HAS_ASSET",
        GRAPH,
        graph_store.DEFAULT_TENANT_ID,
    );
    const legacy_edge = store.getEdgeHydrated(legacy_edge_id) orelse return error.EdgeNotFound;
    try testing.expectEqualStrings(graph_store.DEFAULT_TENANT_ID, legacy_edge.tenant_id);

    // Hidden from t_DEMO, visible to an unscoped (admin) read.
    try testing.expect(!tenant_visibility.edgeTraversable(&store, legacy_edge, T_DEMO));
    try testing.expect(tenant_visibility.edgeTraversable(&store, legacy_edge, null));

    const report = try store.backfillEdgeTenantTags(allocator, false);
    defer graph_store.GraphStore.freeEdgeTagBackfillEntries(allocator, report);
    try testing.expectEqual(@as(usize, 1), report.len);
    try testing.expectEqual(graph_store.GraphStore.EdgeTagBackfillAction.retagged, report[0].action);
    try testing.expectEqual(legacy_edge_id, report[0].edge_id);
    try testing.expectEqualStrings(graph_store.DEFAULT_TENANT_ID, report[0].edge_tenant orelse return error.MissingEdgeTenant);

    const retagged = store.getEdgeHydrated(legacy_edge_id) orelse return error.EdgeNotFound;
    try testing.expectEqualStrings(T_DEMO, retagged.tenant_id);
    try testing.expect(tenant_visibility.edgeTraversable(&store, retagged, T_DEMO));

    const again = try store.backfillEdgeTenantTags(allocator, false);
    defer graph_store.GraphStore.freeEdgeTagBackfillEntries(allocator, again);
    try testing.expectEqual(@as(usize, 0), again.len);
}

// Leak-direction invariant pin (must be GREEN now AND after the fix): a
// genuinely "default"-tagged node must NOT be visible under a t_DEMO filter.
// This proves the GAP-0891 fix tags WRITES correctly — it must never be
// "fixed" by weakening the read filter. Lives in its own test so it runs and
// passes even while the red tests above fail.
test "GAP-0891 invariant: default-tagged rows stay invisible under a t_DEMO filter" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    try store.createGraph(GRAPH);

    const labels = [_][]const u8{"Asset"};
    // One genuine t_DEMO node, one genuine "default" node.
    _ = try store.createNodeWithGraphAndTenant(&labels, GRAPH, T_DEMO);
    _ = try store.createNodeWithGraphAndTenant(&labels, GRAPH, graph_store.DEFAULT_TENANT_ID);

    // The t_DEMO reader sees exactly the one t_DEMO node — the "default" node is
    // excluded by the exact-match filter (isolation must not leak).
    try testing.expectEqual(@as(usize, 1), store.countNodesForGraph(GRAPH, T_DEMO));

    // And adding more "default" rows never increases the t_DEMO count.
    const before = store.countNodesForGraph(GRAPH, T_DEMO);
    _ = try store.createNodeWithGraphAndTenant(&labels, GRAPH, graph_store.DEFAULT_TENANT_ID);
    const after = store.countNodesForGraph(GRAPH, T_DEMO);
    try testing.expectEqual(before, after);
}

// Local copy of graph_store's private tmpDirRealpathAlloc (used by the
// adapter-backed reload test). Builds an absolute path under the test cache.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}
