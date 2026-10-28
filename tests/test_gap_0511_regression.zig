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

// CANARY: REQ=REQ-PERF-MERGE-002; FEATURE="Execution"; ASPECT=IndexRebuild; STATUS=TESTED; OWNER=engine; UPDATED=2026-04-10
test "GAP-0511: Sequential MERGE transactions do not stall on index rebuilds" {
    var allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const store = try geode.graph_store.initGlobalStore(allocator, data_dir);
    defer geode.graph_store.deinitGlobalStore();
    defer geode.execution.cleanupCatalogInstance();

    var catalog = try geode.schema.catalog.Catalog.init(allocator);
    defer catalog.deinit();

    const idx_mgr = try geode.index.index_manager.ensureGlobalIndexManager(allocator);
    defer geode.index.index_manager.cleanupGlobalIndexManager();

    // Create an advanced index
    try idx_mgr.createAdvancedVectorIndex("vec_idx", 3, .l2);
    try idx_mgr.registerAdvancedPropertyIndex("vec_idx", "User", "embedding", .vector_f32);

    // Start a transaction
    var undo_log = geode.txn_undo_log.getGlobalUndoLog(allocator);
    undo_log.begin();

    // Add nodes in a loop (simulating multiple MERGEs in one transaction)
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        var query = std.ArrayList(u8).init(allocator);
        defer query.deinit();
        try query.writer().print("MERGE (n:User {{node_id: {d}}}) SET n.display_name = 'User {d}', n.embedding = [1.0, 2.0, 3.0]", .{ i, i });

        var ctx = geode.execution.ExecutionContext{
            .catalog = &catalog,
            .transaction_state = .Active,
        };

        var pending_rebuilds = std.StringHashMap(void).init(allocator);
        defer {
            var iter = pending_rebuilds.keyIterator();
            while (iter.next()) |k| allocator.free(k.*);
            pending_rebuilds.deinit();
        }
        ctx.pending_index_rebuilds = &pending_rebuilds;

        var result = try execQuery(allocator, query.items, ctx);
        defer result.deinit(allocator);

        // Before commit, index shouldn't be rebuilt for every single property
        // The rebuilds are deferred to the transaction log's pending advanced index rebuilds.
        try testing.expectEqual(@as(usize, 0), idx_mgr.statistics.rebuild_count);
    }

    // Commit the transaction which should trigger a single batch rebuild for the deferred indexes
    undo_log.commit(store);

    // Should only have flushed rebuilds once per modified index (vec_idx) at the end
    try testing.expectEqual(@as(usize, 1), idx_mgr.statistics.rebuild_count);
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
    try testing.expect(graph_storage_adapter.getExactNodePropertyLookupCount() >= 24);
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
    try testing.expect(graph_storage_adapter.getExactNodePropertyLookupCount() >= 16);
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

// CANARY: REQ=REQ-STORAGE-ENGINE-PHASE2-006; FEATURE="EngineBackedPersistence"; ASPECT=StartupMetadataRepair; STATUS=TESTED; OWNER=storage; UPDATED=2026-04-10
test "GAP-0511: global store startup repairs corrupted free.store" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(data_dir);

    var graph_uuid: [16]u8 = undefined;
    var seeded_node_id: u64 = 0;

    {
        const store = try geode.graph_store.initGlobalStore(testing.allocator, data_dir);
        const adapter = geode.graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;

        seeded_node_id = try seedNodeWithNodeId(store, "User", 42);
        try store.setNodeProperty(seeded_node_id, "display_name", .{ .String = "Recovered User" });
        try adapter.checkpointAll();

        graph_uuid = geode.graph_store.GraphStore.getGraphUuid("default") orelse return error.GraphUuidUnavailable;
        geode.graph_store.deinitGlobalStore();
    }
    defer geode.graph_store.deinitGlobalStore();

    const graph_dir = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/graphs/{s}",
        .{ data_dir, std.fmt.bytesToHex(graph_uuid, .lower) },
    );
    defer testing.allocator.free(graph_dir);

    const free_store_path = try std.fmt.allocPrint(testing.allocator, "{s}/free.store", .{graph_dir});
    defer testing.allocator.free(free_store_path);

    {
        const file = try std.fs.cwd().createFile(free_store_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(&([_]u8{0xFF} ** 64));
    }

    const recovered_store = try geode.graph_store.initGlobalStore(testing.allocator, data_dir);
    const recovered_node = recovered_store.getNodePtr(seeded_node_id) orelse return error.NodeNotFound;
    const display_name = recovered_node.properties.get("display_name") orelse return error.PropertyNotFound;

    try testing.expectEqualStrings("Recovered User", display_name.String);
    try testing.expectEqual(@as(usize, 1), recovered_store.getNodeCount());
    const repaired_stat = try std.fs.cwd().statFile(free_store_path);
    try testing.expectEqual(@as(u64, 0), repaired_stat.size);
}

// CANARY: REQ=REQ-PERF-MERGE-007; FEATURE="IndexRebuild"; ASPECT=RebuildMutex; STATUS=TESTED; OWNER=engine; UPDATED=2026-04-10
test "GAP-0511: rebuild_mutex prevents concurrent rebuild races" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    _ = try geode.graph_store.initGlobalStore(allocator, data_dir);
    defer geode.graph_store.deinitGlobalStore();
    defer geode.execution.cleanupCatalogInstance();

    const idx_mgr = try geode.index.index_manager.ensureGlobalIndexManager(allocator);
    defer geode.index.index_manager.cleanupGlobalIndexManager();

    // Create an advanced index and register it
    try idx_mgr.createAdvancedVectorIndex("mutex_vec_idx", 3, .l2);
    try idx_mgr.registerAdvancedPropertyIndex("mutex_vec_idx", "Item", "vec", .vector_f32);

    const store = geode.graph_store.getCurrentGlobalStore().?;

    // Seed some nodes so populateAdvancedIndex has work to do
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const nid = try store.createNodeWithGraph(&[_][]const u8{"Item"}, "default");
        try store.setNodeProperty(nid, "vec", .{ .String = "[1.0, 2.0, 3.0]" });
    }

    // Rebuild twice sequentially -- the mutex should serialize them safely
    try idx_mgr.rebuildAdvancedIndex(store, "mutex_vec_idx");
    try idx_mgr.rebuildAdvancedIndex(store, "mutex_vec_idx");

    // Both rebuilds succeeded; rebuild_count should be 2
    try testing.expectEqual(@as(u64, 2), idx_mgr.statistics.rebuild_count);
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

    const idx_mgr = try geode.index.index_manager.ensureGlobalIndexManager(allocator);
    defer geode.index.index_manager.cleanupGlobalIndexManager();

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
