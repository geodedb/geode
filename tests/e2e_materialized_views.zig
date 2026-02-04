const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const mv = geode.materialized_views;

test "materialized view - create and refresh" {
    const allocator = testing.allocator;

    var manager = try mv.MaterializedViewManager.init(allocator, .{});
    defer manager.deinit();

    try manager.createView(
        "user_stats_mv",
        "RETURN 1 AS user_id, 2 AS post_count",
        .manual,
        null,
    );

    try manager.refreshView("user_stats_mv");

    const stats = try manager.getViewStatistics("user_stats_mv");
    try testing.expect(stats.total_refreshes == 1);
    try testing.expect(stats.successful_refreshes == 1);

    const meta = manager.views.get("user_stats_mv") orelse return error.MissingView;
    try testing.expectEqual(@as(u64, 1), meta.row_count);
    try testing.expect(meta.state == .ready);
}

test "materialized view - manager statistics update" {
    const allocator = testing.allocator;

    var manager = try mv.MaterializedViewManager.init(allocator, .{});
    defer manager.deinit();

    try manager.createView("mv_a", "RETURN 1 AS x", .manual, null);
    try manager.createView("mv_b", "RETURN 2 AS y", .manual, null);

    const stats = manager.getManagerStatistics();
    try testing.expectEqual(@as(u64, 2), stats.total_views);
}

test "materialized view - scheduled refresh job created" {
    const allocator = testing.allocator;

    var manager = try mv.MaterializedViewManager.init(allocator, .{});
    defer manager.deinit();

    try manager.createView(
        "scheduled_mv",
        "RETURN 1 AS x",
        .auto_scheduled,
        3600,
    );

    try testing.expectEqual(@as(usize, 1), manager.refresh_scheduler.scheduled_jobs.items.len);
    try testing.expect(std.mem.eql(u8, manager.refresh_scheduler.scheduled_jobs.items[0].view_name, "scheduled_mv"));
}

test "materialized view - dependency tracking extracts labels" {
    const allocator = testing.allocator;

    var manager = try mv.MaterializedViewManager.init(allocator, .{});
    defer manager.deinit();

    try manager.createView(
        "dep_mv",
        "MATCH (n:Node)-[r:LINKS]->(m:Node) RETURN n, m",
        .manual,
        null,
    );

    const deps = manager.dependency_tracker.view_dependencies.get("dep_mv") orelse return error.MissingDependencies;
    try testing.expect(deps.items.len > 0);
}

test "materialized view - query compatibility check" {
    const allocator = testing.allocator;

    var manager = try mv.MaterializedViewManager.init(allocator, .{});
    defer manager.deinit();

    const query = "RETURN 1 AS x, 2 AS y";
    try manager.createView("compat_mv", query, .manual, null);

    const match = manager.canSatisfyQuery(query);
    try testing.expect(match != null);
    try testing.expect(std.mem.eql(u8, match.?, "compat_mv"));
}
