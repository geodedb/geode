const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// CANARY: REQ=REQ-PERF-MERGE-002; FEATURE="Execution"; ASPECT=IndexRebuild; STATUS=TESTED; OWNER=engine; UPDATED=2026-04-08
test "GAP-0511: Sequential MERGE transactions do not stall on index rebuilds" {
    var allocator = testing.allocator;

    const store = try geode.graph_store.initGlobalStore(allocator);
    defer geode.graph_store.cleanupGlobalStore();

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

        var result = try geode.lib.parseAndExecute(allocator, query.items, ctx);
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
