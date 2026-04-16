// CANARY: REQ=REQ-MATVIEW-INTEGRATION-001; FEATURE="Materialized View Integration Tests"; ASPECT=IntegrationTests; STATUS=EXEMPT; TEST=TestCANARY_REQ_MATVIEW_INTEGRATION_001_IntegrationTests; OWNER=query; UPDATED=2025-10-05

const std = @import("std");
const testing = std.testing;
const materialized_views = @import("../src/query/enhanced_materialized_views.zig");

test "End-to-end materialized view lifecycle" {
    var gpa = std.heap.DebugAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();

    // Create a complex view with dependencies
    const view_id = try manager.createMaterializedView("complex_analytics_view", "SELECT u.region, COUNT(o.id) as order_count, AVG(o.total) as avg_total " ++
        "FROM users u JOIN orders o ON u.id = o.user_id " ++
        "WHERE o.created_date >= '2024-01-01' " ++
        "GROUP BY u.region " ++
        "ORDER BY order_count DESC", materialized_views.RefreshStrategy{
        .timing = .auto_scheduled,
        .method = .incremental,
        .supports_incremental = true,
        .interval_seconds = 3600,
    });

    // Verify initial state
    try testing.expect(view_id == 1);
    const initial_stats = manager.getViewStatistics(view_id).?;
    try testing.expect(initial_stats.refresh_count == 0);
    try testing.expect(initial_stats.last_refresh_timestamp == 0);

    // Perform initial complete refresh
    const complete_result = try manager.refreshMaterializedView(view_id, materialized_views.RefreshOptions{
        .force_complete = true,
        .priority = .high,
    });

    try testing.expect(complete_result.method == .complete);
    try testing.expect(complete_result.success == true);
    try testing.expect(complete_result.rows_processed >= 0);

    // Simulate table changes and incremental refresh
    const affected_rows = [_]materialized_views.RowId{ 1, 2, 3, 4, 5 };
    try manager.handleTableChange("users", .update, &affected_rows);
    try manager.handleTableChange("orders", .insert, &affected_rows[0..2]);

    // Perform incremental refresh
    const incremental_result = try manager.refreshMaterializedView(view_id, materialized_views.RefreshOptions{
        .force_complete = false,
        .priority = .normal,
    });

    try testing.expect(incremental_result.method == .incremental);
    try testing.expect(incremental_result.success == true);

    // Verify statistics after refreshes
    const final_stats = manager.getViewStatistics(view_id).?;
    try testing.expect(final_stats.refresh_count == 2);
    try testing.expect(final_stats.last_refresh_timestamp > 0);
    try testing.expect(final_stats.total_refresh_time_ms > 0);

    // Test view invalidation and cleanup
    try manager.dropMaterializedView(view_id);
    try testing.expect(manager.getViewStatistics(view_id) == null);
}

test "Multi-view dependency management" {
    var gpa = std.heap.DebugAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();

    // Create base view
    const base_view_id = try manager.createMaterializedView("base_users_view", "SELECT * FROM users WHERE active = true AND created_date >= '2023-01-01'", materialized_views.RefreshStrategy{
        .timing = .auto_immediate,
        .method = .incremental,
        .supports_incremental = true,
    });

    // Create dependent view
    const dependent_view_id = try manager.createMaterializedView("user_summary_view", "SELECT region, COUNT(*) as user_count, MAX(last_login) as latest_login " ++
        "FROM base_users_view " ++
        "GROUP BY region", materialized_views.RefreshStrategy{
        .timing = .auto_scheduled,
        .method = .complete,
        .interval_seconds = 1800,
    });

    // Create another dependent view
    const analytics_view_id = try manager.createMaterializedView("user_analytics_view", "SELECT u.region, u.age_group, COUNT(o.id) as orders " ++
        "FROM base_users_view u " ++
        "LEFT JOIN orders o ON u.id = o.user_id " ++
        "GROUP BY u.region, u.age_group", materialized_views.RefreshStrategy{
        .timing = .manual,
        .method = .differential,
    });

    // Simulate changes to the base table
    const affected_users = [_]materialized_views.RowId{ 10, 11, 12 };
    try manager.handleTableChange("users", .update, &affected_users);

    // Refresh base view (should trigger cascading refreshes)
    const base_result = try manager.refreshMaterializedView(base_view_id, materialized_views.RefreshOptions{
        .priority = .high,
    });

    try testing.expect(base_result.success == true);

    // Verify all views exist and have appropriate states
    try testing.expect(manager.getViewStatistics(base_view_id) != null);
    try testing.expect(manager.getViewStatistics(dependent_view_id) != null);
    try testing.expect(manager.getViewStatistics(analytics_view_id) != null);

    // Check metrics
    const metrics = manager.getMetrics();
    try testing.expect(metrics.total_views == 3);
    try testing.expect(metrics.total_refreshes >= 1);
}

test "Refresh scheduler integration" {
    var gpa = std.heap.DebugAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();

    // Create scheduled views with different priorities
    const high_priority_view = try manager.createMaterializedView("high_priority_view", "SELECT COUNT(*) FROM critical_data", materialized_views.RefreshStrategy{
        .timing = .auto_scheduled,
        .method = .incremental,
        .interval_seconds = 60, // 1 minute
    });

    const medium_priority_view = try manager.createMaterializedView("medium_priority_view", "SELECT region, SUM(revenue) FROM sales_data GROUP BY region", materialized_views.RefreshStrategy{
        .timing = .auto_scheduled,
        .method = .complete,
        .interval_seconds = 300, // 5 minutes
    });

    const low_priority_view = try manager.createMaterializedView("low_priority_view", "SELECT * FROM archived_logs WHERE date >= '2024-01-01'", materialized_views.RefreshStrategy{
        .timing = .auto_scheduled,
        .method = .differential,
        .interval_seconds = 3600, // 1 hour
    });

    // Test immediate refresh scheduling
    const immediate_result = try manager.refreshMaterializedView(high_priority_view, materialized_views.RefreshOptions{
        .priority = .immediate,
    });
    try testing.expect(immediate_result.success == true);

    // Test background refresh scheduling
    const background_result = try manager.refreshMaterializedView(low_priority_view, materialized_views.RefreshOptions{
        .priority = .background,
    });
    try testing.expect(background_result.success == true);

    // Verify scheduling metrics
    const metrics = manager.getMetrics();
    try testing.expect(metrics.total_views == 3);
    try testing.expect(metrics.total_refreshes >= 2);
}

test "Error handling and recovery" {
    var gpa = std.heap.DebugAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();

    // Test invalid query creation
    const invalid_result = manager.createMaterializedView("invalid_view", "DELETE FROM users WHERE id = 1", // Invalid for materialized view
        materialized_views.RefreshStrategy{
            .timing = .manual,
            .method = .complete,
        });
    try testing.expectError(error.InvalidQuery, invalid_result);

    // Create a valid view for further testing
    const view_id = try manager.createMaterializedView("test_error_view", "SELECT * FROM test_table", materialized_views.RefreshStrategy{
        .timing = .manual,
        .method = .complete,
    });

    // Test refreshing non-existent view
    const refresh_result = manager.refreshMaterializedView(999, // Non-existent view ID
        materialized_views.RefreshOptions{});
    try testing.expectError(error.ViewNotFound, refresh_result);

    // Test dropping non-existent view
    const drop_result = manager.dropMaterializedView(999);
    try testing.expectError(error.ViewNotFound, drop_result);

    // Verify valid view still exists
    try testing.expect(manager.getViewStatistics(view_id) != null);

    // Test successful cleanup
    try manager.dropMaterializedView(view_id);
    try testing.expect(manager.getViewStatistics(view_id) == null);
}

test "Performance and scalability" {
    var gpa = std.heap.DebugAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();

    const num_views = 25;
    var view_ids = std.ArrayList(u64).init(allocator);
    defer view_ids.deinit();

    // Create many views rapidly
    const start_time = std.time.milliTimestamp();

    for (0..num_views) |i| {
        const view_name = try std.fmt.allocPrint(allocator, "perf_view_{d}", .{i});
        defer allocator.free(view_name);

        const query = try std.fmt.allocPrint(allocator, "SELECT id, name FROM table_{d} WHERE status = 'active'", .{i % 5});
        defer allocator.free(query);

        const view_id = try manager.createMaterializedView(view_name, query, materialized_views.RefreshStrategy{
            .timing = .manual,
            .method = if (i % 3 == 0) .complete else if (i % 3 == 1) .incremental else .differential,
            .supports_incremental = i % 2 == 0,
        });

        try view_ids.append(view_id);
    }

    const creation_time = std.time.milliTimestamp() - start_time;

    // Verify all views were created
    try testing.expect(manager.getMetrics().total_views == num_views);

    // Test rapid refresh operations
    const refresh_start_time = std.time.milliTimestamp();

    for (view_ids.items[0..10]) |view_id| { // Refresh first 10 views
        _ = try manager.refreshMaterializedView(view_id, materialized_views.RefreshOptions{
            .priority = .normal,
        });
    }

    const refresh_time = std.time.milliTimestamp() - refresh_start_time;

    // Verify performance characteristics
    try testing.expect(creation_time < 5000); // Should create 25 views in under 5 seconds
    try testing.expect(refresh_time < 3000); // Should refresh 10 views in under 3 seconds

    // Test bulk operations
    const list_views = try manager.listViews();
    defer allocator.free(list_views);
    try testing.expect(list_views.len == num_views);

    // Clean up all views
    const cleanup_start_time = std.time.milliTimestamp();

    for (view_ids.items) |view_id| {
        try manager.dropMaterializedView(view_id);
    }

    const cleanup_time = std.time.milliTimestamp() - cleanup_start_time;
    try testing.expect(cleanup_time < 2000); // Should clean up in under 2 seconds

    // Verify cleanup
    const final_metrics = manager.getMetrics();
    try testing.expect(final_metrics.views_dropped == num_views);
}

test "Memory efficiency validation" {
    var gpa = std.heap.DebugAllocator(.{});
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.panic("Memory leak detected in materialized view integration test!");
        }
    }
    const allocator = gpa.allocator();

    // Test multiple manager lifecycles
    for (0..5) |iteration| {
        var manager = try materialized_views.MaterializedViewManager.init(allocator);
        defer manager.deinit();

        // Create views with dynamic content
        for (0..10) |i| {
            const view_name = try std.fmt.allocPrint(allocator, "mem_test_view_{d}_{d}", .{ iteration, i });
            defer allocator.free(view_name);

            const query = try std.fmt.allocPrint(allocator, "SELECT * FROM data_table_{d} WHERE timestamp > '{d}'", .{ i, iteration * 1000 });
            defer allocator.free(query);

            const view_id = try manager.createMaterializedView(view_name, query, materialized_views.RefreshStrategy{
                .timing = .manual,
                .method = .complete,
            });

            // Perform refresh to test memory allocation/deallocation
            _ = try manager.refreshMaterializedView(view_id, materialized_views.RefreshOptions{});

            // Drop immediately to test cleanup
            try manager.dropMaterializedView(view_id);
        }

        // Verify no views remain
        const final_list = try manager.listViews();
        defer allocator.free(final_list);
        try testing.expect(final_list.len == 0);
    }
}

test "Concurrent operation simulation" {
    var gpa = std.heap.DebugAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();

    // Create views that would be accessed concurrently
    var view_ids = std.ArrayList(u64).init(allocator);
    defer view_ids.deinit();

    for (0..10) |i| {
        const view_name = try std.fmt.allocPrint(allocator, "concurrent_view_{d}", .{i});
        defer allocator.free(view_name);

        const view_id = try manager.createMaterializedView(view_name, "SELECT * FROM shared_table WHERE partition_id = ?", materialized_views.RefreshStrategy{
            .timing = .auto_immediate,
            .method = .incremental,
            .supports_incremental = true,
        });

        try view_ids.append(view_id);
    }

    // Simulate concurrent operations (in single-threaded test)
    for (0..5) |round| {
        for (view_ids.items) |view_id| {
            // Simulate table changes
            const affected_rows = [_]materialized_views.RowId{ round * 10 + 1, round * 10 + 2 };
            try manager.handleTableChange("shared_table", .update, &affected_rows);

            // Refresh view
            _ = try manager.refreshMaterializedView(view_id, materialized_views.RefreshOptions{
                .priority = if (round % 2 == 0) .high else .normal,
            });
        }
    }

    // Verify system integrity after simulated concurrent access
    const metrics = manager.getMetrics();
    try testing.expect(metrics.total_views == 10);
    try testing.expect(metrics.total_refreshes >= 50); // 10 views * 5 rounds
    try testing.expect(metrics.successful_refreshes == metrics.total_refreshes);
    try testing.expect(metrics.failed_refreshes == 0);

    // Verify all views are still valid
    for (view_ids.items) |view_id| {
        const stats = manager.getViewStatistics(view_id);
        try testing.expect(stats != null);
        try testing.expect(stats.?.refresh_count >= 5);
    }
}
