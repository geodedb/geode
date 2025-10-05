const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const materialized_views = geode.materialized_views;
const graph_storage = geode.graph_common;

// CANARY: REQ=REQ-MATERIALIZED-VIEWS-001; FEATURE="Materialized View Management"; ASPECT=Testing; STATUS=TESTED; TEST=test_materialized_views; OWNER=query; UPDATED=2025-10-05

test "materialized view manager initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const config = materialized_views.MaterializedViewManager.ViewManagerConfig{
        .max_views = 100,
        .max_view_size_mb = 512,
        .default_refresh_interval_seconds = 1800,
        .enable_auto_refresh = true,
        .enable_incremental_refresh = true,
        .max_concurrent_refreshes = 2,
        .refresh_timeout_seconds = 900,
    };
    
    var manager = try materialized_views.MaterializedViewManager.init(allocator, config);
    defer manager.deinit();
    
    try testing.expect(manager.statistics.total_views == 0);
    try testing.expect(manager.statistics.active_refreshes == 0);
    try testing.expect(manager.config.max_views == 100);
    try testing.expect(manager.config.max_view_size_mb == 512);
}

test "create materialized view with manual refresh" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const config = materialized_views.MaterializedViewManager.ViewManagerConfig{};
    var manager = try materialized_views.MaterializedViewManager.init(allocator, config);
    defer manager.deinit();
    
    const view_name = "test_view";
    const source_query = "MATCH (n:Person) RETURN n.name, n.age";
    
    try manager.createView(
        view_name,
        source_query,
        .manual,
        null,
    );
    
    try testing.expect(manager.statistics.total_views == 1);
    
    const metadata = manager.views.get(view_name);
    try testing.expect(metadata != null);
    try testing.expect(std.mem.eql(u8, metadata.?.view_name, view_name));
    try testing.expect(std.mem.eql(u8, metadata.?.source_query, source_query));
    try testing.expect(metadata.?.refresh_strategy == .manual);
    try testing.expect(metadata.?.state == .creating);
    try testing.expect(metadata.?.row_count == 0);
    try testing.expect(metadata.?.refresh_interval_seconds == null);
}

test "create materialized view with auto scheduled refresh" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const config = materialized_views.MaterializedViewManager.ViewManagerConfig{};
    var manager = try materialized_views.MaterializedViewManager.init(allocator, config);
    defer manager.deinit();
    
    const view_name = "scheduled_view";
    const source_query = "MATCH (n:Product) RETURN n.name, n.price";
    const refresh_interval: u64 = 3600; // 1 hour
    
    try manager.createView(
        view_name,
        source_query,
        .auto_scheduled,
        refresh_interval,
    );
    
    const metadata = manager.views.get(view_name);
    try testing.expect(metadata != null);
    try testing.expect(metadata.?.refresh_strategy == .auto_scheduled);
    try testing.expect(metadata.?.refresh_interval_seconds == refresh_interval);
    
    // Check that refresh job was scheduled
    try testing.expect(manager.refresh_scheduler.scheduled_jobs.items.len == 1);
    try testing.expect(std.mem.eql(u8, manager.refresh_scheduler.scheduled_jobs.items[0].view_name, view_name));
}

test "duplicate view creation should fail" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const config = materialized_views.MaterializedViewManager.ViewManagerConfig{};
    var manager = try materialized_views.MaterializedViewManager.init(allocator, config);
    defer manager.deinit();
    
    const view_name = "duplicate_view";
    const source_query = "MATCH (n) RETURN n";
    
    try manager.createView(view_name, source_query, .manual, null);
    
    // Second creation should fail
    const result = manager.createView(view_name, source_query, .manual, null);
    try testing.expectError(error.ViewAlreadyExists, result);
    
    try testing.expect(manager.statistics.total_views == 1);
}

test "max views limit enforcement" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const config = materialized_views.MaterializedViewManager.ViewManagerConfig{
        .max_views = 2,
    };
    var manager = try materialized_views.MaterializedViewManager.init(allocator, config);
    defer manager.deinit();
    
    try manager.createView("view1", "RETURN 1", .manual, null);
    try manager.createView("view2", "RETURN 2", .manual, null);
    
    // Third view should fail
    const result = manager.createView("view3", "RETURN 3", .manual, null);
    try testing.expectError(error.MaxViewsExceeded, result);
    
    try testing.expect(manager.statistics.total_views == 2);
}

test "drop materialized view" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const config = materialized_views.MaterializedViewManager.ViewManagerConfig{};
    var manager = try materialized_views.MaterializedViewManager.init(allocator, config);
    defer manager.deinit();
    
    const view_name = "drop_test_view";
    try manager.createView(view_name, "RETURN 1", .auto_scheduled, 3600);
    
    try testing.expect(manager.statistics.total_views == 1);
    try testing.expect(manager.refresh_scheduler.scheduled_jobs.items.len == 1);
    
    try manager.dropView(view_name);
    
    try testing.expect(manager.statistics.total_views == 0);
    try testing.expect(manager.views.get(view_name) == null);
    try testing.expect(manager.view_data.get(view_name) == null);
    try testing.expect(manager.refresh_scheduler.scheduled_jobs.items.len == 0);
}

test "drop non-existent view should fail" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const config = materialized_views.MaterializedViewManager.ViewManagerConfig{};
    var manager = try materialized_views.MaterializedViewManager.init(allocator, config);
    defer manager.deinit();
    
    const result = manager.dropView("non_existent_view");
    try testing.expectError(error.ViewNotFound, result);
}

test "materialized view data operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var view_data = materialized_views.MaterializedViewData.init(allocator);
    defer view_data.deinit();
    
    // Create test binding
    const test_binding = graph_storage.Binding{
        .variable_name = try allocator.dupe(u8, "n"),
        .value = graph_storage.BindingValue{ .node = graph_storage.Node{
            .id = 1,
            .labels = &.{"Person"},
            .properties = std.StringHashMap(graph_storage.PropertyValue).init(allocator),
        }},
    };
    
    try view_data.addRow(test_binding);
    
    try testing.expect(view_data.rows.items.len == 1);
    try testing.expect(std.mem.eql(u8, view_data.rows.items[0].variable_name, "n"));
    
    const initial_timestamp = view_data.refresh_timestamp;
    std.time.sleep(1000000); // 1ms
    view_data.updateRefreshTimestamp();
    
    try testing.expect(view_data.refresh_timestamp > initial_timestamp);
    
    // Cleanup
    allocator.free(test_binding.variable_name);
}

test "dependency tracker operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tracker = materialized_views.DependencyTracker.init(allocator);
    defer tracker.deinit();
    
    const view_name = "test_view";
    const dependency = "base_table";
    
    try tracker.addDependency(view_name, dependency);
    
    try testing.expect(tracker.view_dependencies.count() == 1);
    
    const deps = tracker.view_dependencies.get(view_name);
    try testing.expect(deps != null);
    try testing.expect(deps.?.items.len == 1);
    try testing.expect(std.mem.eql(u8, deps.?.items[0], dependency));
    
    // Record a change
    try tracker.recordChange("base_table", .insert);
    
    try testing.expect(tracker.change_log.items.len == 1);
    try testing.expect(tracker.change_log.items[0].change_type == .insert);
    try testing.expect(std.mem.eql(u8, tracker.change_log.items[0].table_name, "base_table"));
    try testing.expect(tracker.change_log.items[0].processed == false);
}

test "refresh scheduler operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var scheduler = materialized_views.RefreshScheduler.init(allocator);
    defer scheduler.deinit();
    
    const current_time = std.time.milliTimestamp();
    const view_name1 = "view1";
    const view_name2 = "view2";
    
    // Schedule jobs with different times
    try scheduler.scheduleJob(view_name1, current_time + 1000, .normal);
    try scheduler.scheduleJob(view_name2, current_time + 500, .high);
    
    try testing.expect(scheduler.scheduled_jobs.items.len == 2);
    
    // Jobs should be sorted by scheduled time
    try testing.expect(scheduler.scheduled_jobs.items[0].scheduled_time <= scheduler.scheduled_jobs.items[1].scheduled_time);
    
    // Get next job (should be the one with earlier time)
    const next_job = scheduler.getNextJob(current_time + 600);
    try testing.expect(next_job != null);
    try testing.expect(std.mem.eql(u8, next_job.?.view_name, view_name2));
    try testing.expect(scheduler.scheduled_jobs.items.len == 1);
    
    // Remove remaining job
    try scheduler.removeJob(view_name1);
    try testing.expect(scheduler.scheduled_jobs.items.len == 0);
}

test "view metadata statistics tracking" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var metadata = materialized_views.MaterializedViewMetadata{
        .view_name = try allocator.dupe(u8, "stats_view"),
        .source_query = try allocator.dupe(u8, "RETURN 1"),
        .refresh_strategy = .manual,
        .creation_timestamp = std.time.milliTimestamp(),
        .last_refresh_timestamp = 0,
        .next_refresh_timestamp = null,
        .refresh_interval_seconds = null,
        .state = .ready,
        .row_count = 100,
        .storage_size_bytes = 1024,
        .dependencies = std.ArrayList([]const u8).init(allocator),
        .indexes = std.ArrayList(materialized_views.ViewIndex).init(allocator),
        .statistics = .{
            .total_refreshes = 5,
            .successful_refreshes = 4,
            .failed_refreshes = 1,
            .average_refresh_time_ms = 150.0,
            .total_query_hits = 25,
            .last_query_hit_timestamp = std.time.milliTimestamp(),
            .cache_hit_ratio = 0.8,
            .storage_efficiency = 0.95,
        },
    };
    defer metadata.deinit(allocator);
    
    try testing.expect(metadata.statistics.total_refreshes == 5);
    try testing.expect(metadata.statistics.successful_refreshes == 4);
    try testing.expect(metadata.statistics.failed_refreshes == 1);
    try testing.expect(metadata.statistics.average_refresh_time_ms == 150.0);
    try testing.expect(metadata.statistics.total_query_hits == 25);
    try testing.expect(metadata.statistics.cache_hit_ratio == 0.8);
    try testing.expect(metadata.statistics.storage_efficiency == 0.95);
    try testing.expect(metadata.row_count == 100);
    try testing.expect(metadata.storage_size_bytes == 1024);
}

test "view index management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var view_index = materialized_views.ViewIndex{
        .index_name = try allocator.dupe(u8, "name_index"),
        .column_names = std.ArrayList([]const u8).init(allocator),
        .is_unique = true,
        .creation_timestamp = std.time.milliTimestamp(),
    };
    defer view_index.deinit(allocator);
    
    try view_index.column_names.append(try allocator.dupe(u8, "name"));
    try view_index.column_names.append(try allocator.dupe(u8, "age"));
    
    try testing.expect(std.mem.eql(u8, view_index.index_name, "name_index"));
    try testing.expect(view_index.is_unique == true);
    try testing.expect(view_index.column_names.items.len == 2);
    try testing.expect(std.mem.eql(u8, view_index.column_names.items[0], "name"));
    try testing.expect(std.mem.eql(u8, view_index.column_names.items[1], "age"));
}

test "query compatibility checking" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const config = materialized_views.MaterializedViewManager.ViewManagerConfig{};
    var manager = try materialized_views.MaterializedViewManager.init(allocator, config);
    defer manager.deinit();
    
    const view_name = "compat_view";
    const source_query = "MATCH (n:Person) RETURN n.name";
    
    try manager.createView(view_name, source_query, .manual, null);
    
    // Test exact match (simplified compatibility check)
    const compatible_view = manager.canSatisfyQuery(source_query);
    try testing.expect(compatible_view != null);
    try testing.expect(std.mem.eql(u8, compatible_view.?, view_name));
    
    // Test non-matching query
    const incompatible_view = manager.canSatisfyQuery("MATCH (n:Company) RETURN n.name");
    try testing.expect(incompatible_view == null);
}

test "manager statistics aggregation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const config = materialized_views.MaterializedViewManager.ViewManagerConfig{};
    var manager = try materialized_views.MaterializedViewManager.init(allocator, config);
    defer manager.deinit();
    
    // Create multiple views
    try manager.createView("view1", "RETURN 1", .manual, null);
    try manager.createView("view2", "RETURN 2", .auto_scheduled, 3600);
    
    try testing.expect(manager.statistics.total_views == 2);
    try testing.expect(manager.statistics.active_refreshes == 0);
    try testing.expect(manager.statistics.total_refreshes_completed == 0);
    try testing.expect(manager.statistics.total_query_hits == 0);
    
    const stats = manager.getManagerStatistics();
    try testing.expect(stats.total_views == 2);
    try testing.expect(stats.refresh_success_rate == 0.0); // No refreshes yet
}

test "refresh strategy enumeration coverage" {
    // Ensure all refresh strategies are handled
    const strategies = [_]materialized_views.RefreshStrategy{
        .manual,
        .auto_immediate,
        .auto_scheduled,
        .incremental,
        .streaming,
    };
    
    for (strategies) |strategy| {
        switch (strategy) {
            .manual => try testing.expect(true),
            .auto_immediate => try testing.expect(true),
            .auto_scheduled => try testing.expect(true),
            .incremental => try testing.expect(true),
            .streaming => try testing.expect(true),
        }
    }
}

test "view state enumeration coverage" {
    // Ensure all view states are handled
    const states = [_]materialized_views.ViewState{
        materialized_views.ViewState.creating,
        materialized_views.ViewState.refreshing,
        materialized_views.ViewState.ready,
        materialized_views.ViewState.stale,
        materialized_views.ViewState.failed,
        materialized_views.ViewState.dropping,
    };
    
    for (states) |state| {
        switch (state) {
            .creating => try testing.expect(true),
            .refreshing => try testing.expect(true),
            .ready => try testing.expect(true),
            .stale => try testing.expect(true),
            .failed => try testing.expect(true),
            .dropping => try testing.expect(true),
        }
    }
}