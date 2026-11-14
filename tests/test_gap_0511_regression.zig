// GAP-0511 (PERF) regressions: the adapter-backed MERGE and DELETE paths,
// node and relationship, resolve their nodes through the exact property
// index (no QueryReadSession snapshot, no label scan), and
// `UndoLog.commitDeferRebuilds` leaves the queued advanced-index rebuilds for
// the separate post-lock flush.
//
// SONNY-6528 (6): this file was imported by tests/all_tests.zig only (never
// compiled: it used std APIs Zig 0.16 removed) and is a named step again,
// `zig build test-gap0511-regression`. Two of its cases were not revived,
// their contracts having moved on and being covered by live steps: the
// per-transaction batched vector-index rebuild (geode#875 made a write into
// an indexed label an incremental insert, not a rebuild:
// test-geode875-incremental-index) and the sequential `rebuildAdvancedIndex`
// mutex case (the function is gone; the rebuild mutex is covered by
// test-vector-index-reader-quiescence, test-sonny6421-index-maintenance and
// test-geode875-nonblocking-backfill).

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const graph_storage_adapter = geode.graph_storage_adapter;

fn execQuery(
    allocator: std.mem.Allocator,
    query: []const u8,
    ctx: geode.execution.ExecutionContext,
) !geode.execution.ExecutionResult {
    var parse_result = try geode.parse(allocator, query, .{});
    defer parse_result.deinit();
    return geode.execution.executeProgramWithContext(allocator, &parse_result.program, ctx);
}

fn seedNodeWithNodeId(
    store: *geode.graph_store.GraphStore,
    label: []const u8,
    external_id: i64,
) !u64 {
    const node_id = try store.createNodeWithGraph(&[_][]const u8{label}, "default");
    try store.setNodeProperty(node_id, "node_id", .{ .Int = external_id });
    return node_id;
}

// CANARY: REQ=REQ-PERF-MERGE-003; FEATURE="Execution"; ASPECT=AdapterMergeSnapshotElision; STATUS=TESTED; OWNER=engine; UPDATED=2026-04-10
test "GAP-0511: Adapter-backed MERGE avoids QueryReadSession snapshots" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(data_dir);

    const store = try geode.graph_store.initGlobalStore(testing.allocator, data_dir);
    defer geode.graph_store.deinitGlobalStore();
    _ = store;

    const catalog = try geode.execution.ensureCatalogInstance(testing.allocator);
    defer geode.execution.cleanupCatalogInstance();

    const ctx = geode.execution.ExecutionContext{
        .catalog = catalog,
    };

    geode.graph_store.resetQueryReadSessionInitCount();
    geode.graph_store.resetGetNodesByLabelsCount();
    graph_storage_adapter.resetLookupCounters();

    var i: usize = 0;
    while (i < 24) : (i += 1) {
        const query = try std.fmt.allocPrint(
            testing.allocator,
            "MERGE (n:User {{node_id: {d}}}) SET n.display_name = 'User {d}'",
            .{ i, i },
        );
        defer testing.allocator.free(query);

        var result = try execQuery(testing.allocator, query, ctx);
        defer result.deinit(testing.allocator);
    }

    try testing.expectEqual(@as(u64, 0), geode.graph_store.getQueryReadSessionInitCount());
    try testing.expectEqual(@as(u64, 0), geode.graph_store.getNodesByLabelsCallCount());
    // SONNY-6528 (6): a MERGE resolves its node through the MERGE property
    // index (GAP-0894), not the exact property index this counted; the
    // adapter's label scan is not used either.
    try testing.expectEqual(@as(u64, 0), graph_storage_adapter.getLabelScanLookupCount());
    try testing.expectEqual(@as(usize, 24), geode.graph_store.getCurrentGlobalStore().?.getNodeCount());
}

// CANARY: REQ=REQ-PERF-DELETE-005; FEATURE="Execution"; ASPECT=AdapterDeleteSnapshotElision; STATUS=TESTED; OWNER=engine; UPDATED=2026-04-10
test "GAP-0511: Adapter-backed DELETE avoids QueryReadSession snapshots" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(data_dir);

    const store = try geode.graph_store.initGlobalStore(testing.allocator, data_dir);
    defer geode.graph_store.deinitGlobalStore();

    const catalog = try geode.execution.ensureCatalogInstance(testing.allocator);
    defer geode.execution.cleanupCatalogInstance();

    var i: usize = 0;
    while (i < 24) : (i += 1) {
        _ = try seedNodeWithNodeId(store, "User", @intCast(i));
    }

    const ctx = geode.execution.ExecutionContext{
        .catalog = catalog,
    };

    geode.graph_store.resetQueryReadSessionInitCount();
    geode.graph_store.resetGetNodesByLabelsCount();
    graph_storage_adapter.resetLookupCounters();

    i = 0;
    while (i < 24) : (i += 1) {
        const query = try std.fmt.allocPrint(
            testing.allocator,
            "MATCH (n:User {{node_id: {d}}}) DELETE n",
            .{i},
        );
        defer testing.allocator.free(query);

        var result = try execQuery(testing.allocator, query, ctx);
        defer result.deinit(testing.allocator);
    }

    try testing.expectEqual(@as(u64, 0), geode.graph_store.getQueryReadSessionInitCount());
    try testing.expectEqual(@as(u64, 0), geode.graph_store.getNodesByLabelsCallCount());
    try testing.expect(graph_storage_adapter.getExactNodePropertyLookupCount() >= 24);
    try testing.expectEqual(@as(usize, 0), geode.graph_store.getCurrentGlobalStore().?.getNodeCount());
}

// CANARY: REQ=REQ-PERF-MERGE-006; FEATURE="Execution"; ASPECT=RelationshipMergeEndpointLookup; STATUS=TESTED; OWNER=engine; UPDATED=2026-04-10
test "GAP-0511: Relationship MERGE resolves endpoints without label scans" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(data_dir);

    const store = try geode.graph_store.initGlobalStore(testing.allocator, data_dir);
    defer geode.graph_store.deinitGlobalStore();

    const catalog = try geode.execution.ensureCatalogInstance(testing.allocator);
    defer geode.execution.cleanupCatalogInstance();

    var i: usize = 0;
    while (i < 32) : (i += 1) {
        _ = try seedNodeWithNodeId(store, "User", @intCast(i + 1));
    }

    const ctx = geode.execution.ExecutionContext{
        .catalog = catalog,
    };

    geode.graph_store.resetQueryReadSessionInitCount();
    geode.graph_store.resetGetNodesByLabelsCount();
    graph_storage_adapter.resetLookupCounters();

    i = 0;
    while (i < 16) : (i += 1) {
        var result = try execQuery(
            testing.allocator,
            "MERGE (a:User {node_id: 1})-[:KNOWS]->(b:User {node_id: 2})",
            ctx,
        );
        defer result.deinit(testing.allocator);
    }

    try testing.expectEqual(@as(u64, 0), geode.graph_store.getQueryReadSessionInitCount());
    try testing.expectEqual(@as(u64, 0), geode.graph_store.getNodesByLabelsCallCount());
    // SONNY-6528 (6): as in the node MERGE case.
    try testing.expectEqual(@as(u64, 0), graph_storage_adapter.getLabelScanLookupCount());
    try testing.expectEqual(@as(usize, 1), geode.graph_store.getCurrentGlobalStore().?.getEdgeCount());
}

// CANARY: REQ=REQ-PERF-DELETE-006; FEATURE="Execution"; ASPECT=RelationshipDeleteEndpointLookup; STATUS=TESTED; OWNER=engine; UPDATED=2026-04-10
test "GAP-0511: Relationship DELETE resolves endpoints without label scans" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(data_dir);

    const store = try geode.graph_store.initGlobalStore(testing.allocator, data_dir);
    defer geode.graph_store.deinitGlobalStore();

    const catalog = try geode.execution.ensureCatalogInstance(testing.allocator);
    defer geode.execution.cleanupCatalogInstance();

    const source_id = try seedNodeWithNodeId(store, "User", 1);
    const target_id = try seedNodeWithNodeId(store, "User", 2);
    _ = try store.createEdgeWithGraph(source_id, target_id, "KNOWS", "default");

    var prev_noise_node: ?u64 = null;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const node_id = try seedNodeWithNodeId(store, "User", @intCast(i + 10));
        if (prev_noise_node) |prev| {
            _ = try store.createEdgeWithGraph(prev, node_id, "NOISE", "default");
        }
        prev_noise_node = node_id;
    }

    const ctx = geode.execution.ExecutionContext{
        .catalog = catalog,
    };

    geode.graph_store.resetQueryReadSessionInitCount();
    geode.graph_store.resetGetNodesByLabelsCount();
    graph_storage_adapter.resetLookupCounters();

    var result = try execQuery(
        testing.allocator,
        "MATCH (a:User {node_id: 1})-[r:KNOWS]->(b:User {node_id: 2}) DELETE r",
        ctx,
    );
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 0), geode.graph_store.getQueryReadSessionInitCount());
    try testing.expectEqual(@as(u64, 0), geode.graph_store.getNodesByLabelsCallCount());
    try testing.expect(graph_storage_adapter.getExactNodePropertyLookupCount() >= 1);
    try testing.expectEqual(@as(usize, 31), geode.graph_store.getCurrentGlobalStore().?.getEdgeCount());
}

// CANARY: REQ=REQ-PERF-MERGE-008; FEATURE="IndexRebuild"; ASPECT=CommitDeferRebuilds; STATUS=TESTED; OWNER=engine; UPDATED=2026-04-10
test "GAP-0511: commitDeferRebuilds leaves pending rebuilds for separate flush" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const store = try geode.graph_store.initGlobalStore(allocator, data_dir);
    defer geode.graph_store.deinitGlobalStore();
    defer geode.execution.cleanupCatalogInstance();

    const idx_mgr = try geode.index_manager.ensureGlobalIndexManager(allocator);
    defer geode.index_manager.cleanupGlobalIndexManager();

    try idx_mgr.createAdvancedVectorIndex("defer_idx", 3, .l2);
    try idx_mgr.registerAdvancedPropertyIndex("defer_idx", "Node", "embedding", .vector_f32);

    var undo_log = geode.txn_undo_log.getGlobalUndoLog(allocator);
    undo_log.begin();

    // Queue a rebuild via the undo log
    try undo_log.queueAdvancedIndexRebuild("defer_idx");

    // commitDeferRebuilds should clear entries/savepoints and deactivate,
    // but NOT flush pending rebuilds.
    undo_log.commitDeferRebuilds();
    try testing.expect(!undo_log.active);
    try testing.expectEqual(@as(u64, 0), idx_mgr.statistics.rebuild_count);

    // Now flush pending rebuilds separately (simulates post-lock-release flush)
    undo_log.flushPendingRebuilds(store);
    try testing.expectEqual(@as(u64, 1), idx_mgr.statistics.rebuild_count);
}
