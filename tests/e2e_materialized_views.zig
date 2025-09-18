const std = @import("std");
const testing = std.testing;
const mv = @import("../src/storage/materialized_views.zig");
const storage = @import("../src/storage/interface.zig");

test "materialized view - create and populate" {
    const allocator = testing.allocator;

    var storage_engine = try storage.StorageEngine.init(allocator, .{});
    defer storage_engine.deinit();

    var manager = try mv.MaterializedViewManager.init(allocator, &storage_engine);
    defer manager.deinit();

    // Create a materialized view
    try manager.createMaterializedView(
        "user_stats_mv",
        \\MATCH (u:User)-[r:POSTED]->(p:Post)
        \\RETURN u.id AS user_id, COUNT(p) AS post_count
        \\GROUP BY u.id
    ,
        .{
            .storage_type = .heap,
            .refresh_method = .complete,
            .refresh_timing = .on_demand,
            .populate_initially = true,
        },
    );

    // Verify view was created
    try testing.expectEqual(@as(u64, 1), manager.statistics.total_views);
    try testing.expectEqual(@as(u64, 1), manager.statistics.active_views);

    // Check view exists in catalog
    const view = manager.view_catalog.views.get("user_stats_mv");
    try testing.expect(view != null);
}

test "materialized view - incremental refresh" {
    const allocator = testing.allocator;

    var storage_engine = try storage.StorageEngine.init(allocator, .{});
    defer storage_engine.deinit();

    var manager = try mv.MaterializedViewManager.init(allocator, &storage_engine);
    defer manager.deinit();

    // Create view with incremental refresh
    try manager.createMaterializedView(
        "incremental_mv",
        "MATCH (n) RETURN n.id, n.timestamp WHERE n.timestamp > $last_refresh",
        .{
            .refresh_method = .incremental,
            .enable_incremental = true,
            .refresh_timing = .{ .continuous = .{
                .lag_threshold_ms = 1000,
                .batch_size = 100,
            } },
        },
    );

    const view_id: u64 = 1; // First view created

    // Perform incremental refresh
    try manager.refreshView(view_id, .{
        .force_complete = false,
        .wait_for_completion = true,
    });

    // Check refresh statistics
    const view = manager.view_catalog.view_by_id.get(view_id);
    try testing.expect(view != null);
    try testing.expect(view.?.statistics.refresh_count > 0);
}

test "materialized view - automatic refresh on data changes" {
    const allocator = testing.allocator;

    var storage_engine = try storage.StorageEngine.init(allocator, .{});
    defer storage_engine.deinit();

    var manager = try mv.MaterializedViewManager.init(allocator, &storage_engine);
    defer manager.deinit();

    // Create view with automatic refresh
    try manager.createMaterializedView(
        "auto_refresh_mv",
        "MATCH (n:Node) RETURN COUNT(n) AS node_count",
        .{
            .refresh_method = .incremental,
            .refresh_timing = .on_commit,
        },
    );

    // Simulate data change event
    const invalidation_event = mv.DependencyTracker.InvalidationEvent{
        .timestamp = std.time.milliTimestamp(),
        .source_object = 100, // Table ID
        .event_type = .insert,
        .affected_views = try allocator.dupe(u64, &[_]u64{1}),
        .propagation_depth = 1,
    };

    try manager.dependency_tracker.invalidation_queue.append(invalidation_event);

    // Verify invalidation was queued
    try testing.expectEqual(@as(usize, 1), manager.dependency_tracker.invalidation_queue.items.len);
}

test "materialized view - query rewriting to use views" {
    const allocator = testing.allocator;

    var storage_engine = try storage.StorageEngine.init(allocator, .{});
    defer storage_engine.deinit();

    var manager = try mv.MaterializedViewManager.init(allocator, &storage_engine);
    defer manager.deinit();

    // Create a materialized view for aggregations
    try manager.createMaterializedView(
        "sales_summary_mv",
        \\MATCH (s:Sale)
        \\RETURN s.product_id AS product_id,
        \\       SUM(s.amount) AS total_sales,
        \\       COUNT(s) AS sale_count
        \\GROUP BY s.product_id
    ,
        .{
            .storage_type = .columnar,
            .primary_key = &[_][]const u8{"product_id"},
        },
    );

    // Test query rewriting
    const original_query =
        \\MATCH (s:Sale)
        \\WHERE s.product_id = 123
        \\RETURN SUM(s.amount) AS total
    ;

    // Parse query (simplified for test)
    var ast_query = ast.Query{
        .type = .match,
        .pattern = undefined,
    };

    const rewritten = try manager.rewriteQuery(&ast_query);

    // Should rewrite to use materialized view
    try testing.expect(rewritten != &ast_query); // Different query object if rewritten
}

test "materialized view - scheduled refresh" {
    const allocator = testing.allocator;

    var storage_engine = try storage.StorageEngine.init(allocator, .{});
    defer storage_engine.deinit();

    var manager = try mv.MaterializedViewManager.init(allocator, &storage_engine);
    defer manager.deinit();

    // Create view with scheduled refresh
    try manager.createMaterializedView(
        "scheduled_mv",
        "MATCH (n) RETURN COUNT(n)",
        .{
            .refresh_timing = .{
                .scheduled = .{
                    .interval_seconds = 3600, // Every hour
                    .last_refresh = 0,
                    .next_refresh = std.time.milliTimestamp() + 3600000,
                },
            },
        },
    );

    // Check scheduler
    const schedule_entry = manager.refresh_manager.scheduler.schedule_table.get(1);
    try testing.expect(schedule_entry != null);
    try testing.expectEqual(@as(u64, 3600), schedule_entry.?.interval_seconds.?);
}

test "materialized view - dependency tracking" {
    const allocator = testing.allocator;

    var storage_engine = try storage.StorageEngine.init(allocator, .{});
    defer storage_engine.deinit();

    var manager = try mv.MaterializedViewManager.init(allocator, &storage_engine);
    defer manager.deinit();

    // Create base view
    try manager.createMaterializedView(
        "base_mv",
        "MATCH (n:Node) RETURN n.id, n.value",
        .{},
    );

    // Create dependent view
    try manager.createMaterializedView(
        "derived_mv",
        "MATCH (n) WHERE n IN base_mv RETURN SUM(n.value)",
        .{},
    );

    // Check dependency graph
    const graph = &manager.dependency_tracker.dependency_graph;
    try testing.expect(graph.nodes.count() >= 2);

    // Verify dependency relationship exists
    if (graph.nodes.get(2)) |derived_node| {
        try testing.expect(derived_node.dependencies.items.len > 0);
        try testing.expectEqual(@as(u64, 1), derived_node.dependencies.items[0]);
    }
}
