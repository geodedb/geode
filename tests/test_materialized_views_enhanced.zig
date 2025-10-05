// CANARY: REQ=REQ-MATVIEW-TEST-001; FEATURE="Materialized View Tests"; ASPECT=UnitTests; STATUS=IMPL; TEST=TestCANARY_REQ_MATVIEW_TEST_001_UnitTests; OWNER=query; UPDATED=2025-10-05

const std = @import("std");
const testing = std.testing;
const materialized_views = @import("../src/query/enhanced_materialized_views.zig");

test "MaterializedViewManager initialization and cleanup" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();
    
    // Verify initial state
    const metrics = manager.getMetrics();
    try testing.expect(metrics.total_views == 0);
    try testing.expect(metrics.total_refreshes == 0);
}

test "Create and drop materialized view" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();
    
    // Create a materialized view
    const refresh_strategy = materialized_views.RefreshStrategy{
        .timing = .manual,
        .method = .complete,
        .supports_incremental = false,
    };
    
    const view_id = try manager.createMaterializedView(
        "test_view",
        "SELECT * FROM users WHERE active = true",
        refresh_strategy
    );
    
    // Verify view was created
    try testing.expect(view_id == 1);
    const metrics_after_create = manager.getMetrics();
    try testing.expect(metrics_after_create.total_views == 1);
    
    // Verify view statistics
    const stats = manager.getViewStatistics(view_id);
    try testing.expect(stats != null);
    try testing.expect(stats.?.refresh_count == 0);
    
    // Drop the view
    try manager.dropMaterializedView(view_id);
    
    // Verify view was dropped
    const metrics_after_drop = manager.getMetrics();
    try testing.expect(metrics_after_drop.views_dropped == 1);
    
    // Verify view no longer exists
    const stats_after_drop = manager.getViewStatistics(view_id);
    try testing.expect(stats_after_drop == null);
}

test "Refresh strategies and methods" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();
    
    // Test different refresh strategies
    const strategies = [_]materialized_views.RefreshStrategy{
        .{
            .timing = .manual,
            .method = .complete,
        },
        .{
            .timing = .auto_immediate,
            .method = .incremental,
            .supports_incremental = true,
        },
        .{
            .timing = .scheduled,
            .method = .differential,
            .interval_seconds = 3600,
        },
    };
    
    for (strategies, 0..) |strategy, i| {
        const view_name = try std.fmt.allocPrint(allocator, "test_view_{d}", .{i});
        defer allocator.free(view_name);
        
        const view_id = try manager.createMaterializedView(
            view_name,
            "MATCH (n:Node) RETURN n.id",
            strategy
        );
        
        try testing.expect(view_id == i + 1);
    }
    
    // Verify all views were created
    const metrics = manager.getMetrics();
    try testing.expect(metrics.total_views == 3);
}

test "View refresh with different options" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();
    
    const refresh_strategy = materialized_views.RefreshStrategy{
        .timing = .manual,
        .method = .complete,
        .supports_incremental = true,
    };
    
    const view_id = try manager.createMaterializedView(
        "refresh_test_view",
        "MATCH (p:Person) WHERE p.age > 18 RETURN p",
        refresh_strategy
    );
    
    // Test complete refresh
    const complete_options = materialized_views.RefreshOptions{
        .force_complete = true,
        .priority = .high,
    };
    
    const complete_result = try manager.refreshMaterializedView(view_id, complete_options);
    try testing.expect(complete_result.method == .complete);
    try testing.expect(complete_result.rows_processed >= 0);
    
    // Test incremental refresh
    const incremental_options = materialized_views.RefreshOptions{
        .force_complete = false,
        .priority = .normal,
    };
    
    const incremental_result = try manager.refreshMaterializedView(view_id, incremental_options);
    try testing.expect(incremental_result.method == .incremental);
    
    // Verify view statistics were updated
    const stats = manager.getViewStatistics(view_id).?;
    try testing.expect(stats.refresh_count == 2);
    try testing.expect(stats.last_refresh_duration_ms > 0);
}

test "Dependency tracking" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();
    
    // Create views with dependencies
    const view1_id = try manager.createMaterializedView(
        "users_view",
        "SELECT * FROM users WHERE active = true",
        materialized_views.RefreshStrategy{
            .timing = .auto_immediate,
            .method = .incremental,
            .supports_incremental = true,
        }
    );
    
    const view2_id = try manager.createMaterializedView(
        "orders_view", 
        "SELECT * FROM orders JOIN users ON orders.user_id = users.id",
        materialized_views.RefreshStrategy{
            .timing = .auto_scheduled,
            .method = .complete,
        }
    );
    
    // Test table change handling
    const affected_rows = [_]materialized_views.RowId{1, 2, 3};
    try manager.handleTableChange(
        "users",
        .update,
        &affected_rows
    );
    
    // Verify views exist
    try testing.expect(manager.getViewStatistics(view1_id) != null);
    try testing.expect(manager.getViewStatistics(view2_id) != null);
}

test "View catalog operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();
    
    // Create multiple views
    const view_names = [_][]const u8{
        "products_view",
        "customers_view",
        "analytics_view",
    };
    
    var view_ids = std.ArrayList(u64).init(allocator);
    defer view_ids.deinit();
    
    for (view_names) |name| {
        const view_id = try manager.createMaterializedView(
            name,
            "MATCH (n) RETURN count(n)",
            materialized_views.RefreshStrategy{
                .timing = .manual,
                .method = .complete,
            }
        );
        try view_ids.append(view_id);
    }
    
    // List all views
    const view_list = try manager.listViews();
    defer allocator.free(view_list);
    
    try testing.expect(view_list.len == 3);
    
    // Verify view information
    for (view_list) |view_info| {
        try testing.expect(view_info.id > 0);
        try testing.expect(view_info.name.len > 0);
        try testing.expect(view_info.query.len > 0);
        try testing.expect(view_info.is_valid == true);
    }
}

test "Query validation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();
    
    const refresh_strategy = materialized_views.RefreshStrategy{
        .timing = .manual,
        .method = .complete,
    };
    
    // Valid queries should succeed
    const valid_queries = [_][]const u8{
        "SELECT * FROM users",
        "MATCH (n:Node) RETURN n",
        "SELECT COUNT(*) FROM products WHERE price > 100",
    };
    
    for (valid_queries, 0..) |query, i| {
        const view_name = try std.fmt.allocPrint(allocator, "valid_view_{d}", .{i});
        defer allocator.free(view_name);
        
        const view_id = manager.createMaterializedView(view_name, query, refresh_strategy) catch |err| {
            std.debug.print("Failed to create view with query: {s}, error: {}\n", .{ query, err });
            return err;
        };
        
        try testing.expect(view_id > 0);
    }
    
    // Invalid queries should fail
    const invalid_queries = [_][]const u8{
        "INSERT INTO users VALUES (1, 'John')",
        "UPDATE products SET price = 200",
        "DELETE FROM orders WHERE id = 1",
        "CREATE TABLE test (id INT)",
    };
    
    for (invalid_queries, 0..) |query, i| {
        const view_name = try std.fmt.allocPrint(allocator, "invalid_view_{d}", .{i});
        defer allocator.free(view_name);
        
        const result = manager.createMaterializedView(view_name, query, refresh_strategy);
        try testing.expectError(error.InvalidQuery, result);
    }
}

test "View metrics and statistics" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();
    
    // Create views and perform operations
    const view_id = try manager.createMaterializedView(
        "metrics_test_view",
        "SELECT * FROM transactions WHERE amount > 1000",
        materialized_views.RefreshStrategy{
            .timing = .manual,
            .method = .complete,
        }
    );
    
    // Perform multiple refreshes
    const refresh_options = materialized_views.RefreshOptions{
        .force_complete = true,
    };
    
    for (0..3) |_| {
        _ = try manager.refreshMaterializedView(view_id, refresh_options);
        // Small delay to ensure different timestamps
        std.time.sleep(1_000_000); // 1ms
    }
    
    // Check view statistics
    const view_stats = manager.getViewStatistics(view_id).?;
    try testing.expect(view_stats.refresh_count == 3);
    try testing.expect(view_stats.total_refresh_time_ms > 0);
    
    // Check global metrics
    const global_metrics = manager.getMetrics();
    try testing.expect(global_metrics.total_views == 1);
    try testing.expect(global_metrics.total_refreshes == 3);
    try testing.expect(global_metrics.successful_refreshes == 3);
    try testing.expect(global_metrics.failed_refreshes == 0);
    
    // Drop view and check metrics
    try manager.dropMaterializedView(view_id);
    
    const final_metrics = manager.getMetrics();
    try testing.expect(final_metrics.views_dropped == 1);
}

test "Refresh scheduler functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var scheduler = try materialized_views.RefreshScheduler.init(allocator);
    defer scheduler.deinit();
    
    // Schedule refreshes
    try scheduler.scheduleRefresh(1, .immediate);
    try scheduler.scheduleRefresh(2, .incremental);
    try scheduler.scheduleRefresh(3, .scheduled);
    
    // Get next refresh (should be immediate)
    const next_refresh = scheduler.getNextRefresh();
    try testing.expect(next_refresh != null);
    try testing.expect(next_refresh.?.view_id == 1);
    try testing.expect(next_refresh.?.timing == .immediate);
    
    // Schedule refresh at specific time
    const future_time = std.time.milliTimestamp() + 10000; // 10 seconds from now
    try scheduler.scheduleRefreshAt(4, future_time);
    
    // Verify scheduled refresh
    const scheduled_refresh = scheduler.getNextRefresh();
    try testing.expect(scheduled_refresh != null);
    try testing.expect(scheduled_refresh.?.view_id == 2); // Next in queue
}

test "Memory management and cleanup" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Test that creating and dropping many views doesn't leak memory
    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();
    
    const num_views = 50;
    var view_ids = std.ArrayList(u64).init(allocator);
    defer view_ids.deinit();
    
    // Create many views
    for (0..num_views) |i| {
        const view_name = try std.fmt.allocPrint(allocator, "test_view_{d}", .{i});
        defer allocator.free(view_name);
        
        const view_id = try manager.createMaterializedView(
            view_name,
            "MATCH (n) RETURN n LIMIT 10",
            materialized_views.RefreshStrategy{
                .timing = .manual,
                .method = .complete,
            }
        );
        
        try view_ids.append(view_id);
    }
    
    try testing.expect(manager.getMetrics().total_views == num_views);
    
    // Drop all views
    for (view_ids.items) |view_id| {
        try manager.dropMaterializedView(view_id);
    }
    
    try testing.expect(manager.getMetrics().views_dropped == num_views);
    
    // Verify no views exist
    const final_list = try manager.listViews();
    defer allocator.free(final_list);
    try testing.expect(final_list.len == 0);
}

test "Dependency tracker edge cases" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tracker = try materialized_views.DependencyTracker.init(allocator);
    defer tracker.deinit();
    
    // Test empty dependencies
    const empty_deps = try allocator.alloc(materialized_views.Dependency, 0);
    defer allocator.free(empty_deps);
    
    try tracker.registerView(1, empty_deps);
    
    // Test getting dependencies for non-existent table
    const non_existent_deps = try tracker.getDependentViews("non_existent_table");
    defer allocator.free(non_existent_deps);
    try testing.expect(non_existent_deps.len == 0);
    
    // Test unregistering non-existent view
    tracker.unregisterView(999); // Should not crash
    
    // Test multiple dependencies on same table
    var deps = std.ArrayList(materialized_views.Dependency).init(allocator);
    defer deps.deinit();
    
    try deps.append(materialized_views.Dependency{
        .type = .table,
        .name = try allocator.dupe(u8, "test_table"),
        .columns = try allocator.alloc([]const u8, 0),
    });
    
    const dep_slice = try deps.toOwnedSlice();
    defer {
        for (dep_slice) |dep| {
            allocator.free(dep.name);
            allocator.free(dep.columns);
        }
        allocator.free(dep_slice);
    }
    
    try tracker.registerView(2, dep_slice);
    try tracker.registerView(3, dep_slice);
    
    const dependent_views = try tracker.getDependentViews("test_table");
    defer allocator.free(dependent_views);
    try testing.expect(dependent_views.len == 2);
}

test "Query rewriter basic functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var rewriter = try materialized_views.QueryRewriter.init(allocator);
    defer rewriter.deinit();
    
    var catalog = try materialized_views.ViewCatalog.init(allocator);
    defer catalog.deinit();
    
    // Test query rewriting (currently returns null)
    const query = "SELECT * FROM users WHERE active = true";
    const rewrite = try rewriter.findApplicableViews(query, &catalog);
    
    // Currently expected to return null (not implemented)
    try testing.expect(rewrite == null);
}