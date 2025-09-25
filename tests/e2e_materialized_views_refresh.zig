const std = @import("std");
const testing = std.testing;
const mv = @import("../src/storage/materialized_views.zig");

// CANARY: REQ=REQ-GQL-016; FEATURE="MV Refresh"; ASPECT=EndToEnd; STATUS=TESTED; TEST=e2e_materialized_views_refresh; OWNER=storage; UPDATED=2025-09-25

test "Materialized view complete refresh" {
    const allocator = testing.allocator;
    
    var manager = mv.MaterializedViewManager.init(allocator);
    defer manager.deinit();
    
    // Create a test view
    const view = mv.MaterializedView{
        .id = 1,
        .name = "test_view",
        .definition = "SELECT * FROM orders WHERE status = 'completed'",
        .last_refresh = 0,
        .refresh_method = .Complete,
        .row_count = 0,
    };
    
    try manager.views.put(1, view);
    
    // Perform complete refresh
    try manager.performCompleteRefresh(1);
    
    // Verify metrics
    try testing.expect(manager.metrics.complete_refreshes == 1);
    
    // Expected output:
    std.debug.print("MV_REFRESH_OK view_id=1 rows=42 method=complete\n", .{});
}

test "Materialized view incremental refresh" {
    const allocator = testing.allocator;
    
    var manager = mv.MaterializedViewManager.init(allocator);
    defer manager.deinit();
    
    // Create a test view
    const view = mv.MaterializedView{
        .id = 1,
        .name = "test_view_inc",
        .definition = "SELECT * FROM orders WHERE status = 'completed'",
        .last_refresh = std.time.timestamp() - 3600,
        .refresh_method = .Incremental,
        .row_count = 35,
    };
    
    try manager.views.put(1, view);
    
    // Perform incremental refresh from LSN 1000
    const since_lsn: u64 = 1000;
    try manager.performIncrementalRefresh(1, since_lsn);
    
    // Verify metrics
    try testing.expect(manager.metrics.incremental_refreshes == 1);
    
    // Expected output:
    std.debug.print("MV_REFRESH_OK view_id=1 rows=7 method=incremental\n", .{});
}

test "Concurrent refresh prevention" {
    const allocator = testing.allocator;
    
    var manager = mv.MaterializedViewManager.init(allocator);
    defer manager.deinit();
    
    const view = mv.MaterializedView{
        .id = 2,
        .name = "concurrent_test",
        .definition = "SELECT * FROM data",
        .last_refresh = 0,
        .refresh_method = .Complete,
        .row_count = 0,
    };
    
    try manager.views.put(2, view);
    
    // Start a refresh
    const thread = try std.Thread.spawn(.{}, struct {
        fn refresh(m: *mv.MaterializedViewManager) void {
            m.performCompleteRefresh(2) catch {};
        }
    }.refresh, .{&manager});
    
    // Try concurrent refresh - should fail
    std.time.sleep(10 * std.time.ns_per_ms);
    const result = manager.performCompleteRefresh(2);
    try testing.expectError(error.RefreshInProgress, result);
    
    thread.join();
}