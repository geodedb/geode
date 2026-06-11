// CANARY: REQ=REQ-MATVIEW-TEST-001; FEATURE="Materialized View Tests"; ASPECT=UnitTests; STATUS=TESTED; TEST=tests/test_materialized_views_enhanced.zig; OWNER=query; UPDATED=2026-06-11
//
// GAP-0876: named regression suite for the enhanced materialized view
// manager (`src/query/enhanced_materialized_views.zig`), run via
// `zig build test-gap0876`. Covers lifecycle, refresh, dependency
// tracking, scheduling, and — the GAP-0876 core — exact-match query
// rewrite with proof that rewrite results are served from the view's
// materialized snapshot, not from base data.

const std = @import("std");
const testing = std.testing;
const materialized_views = @import("geode").enhanced_materialized_views;

test "MaterializedViewManager initialization and cleanup" {
    const allocator = testing.allocator;

    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();

    const metrics = manager.getMetrics();
    try testing.expect(metrics.total_views == 0);
    try testing.expect(metrics.total_refreshes == 0);
}

test "Create and drop materialized view" {
    const allocator = testing.allocator;

    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();

    const refresh_strategy = materialized_views.RefreshStrategy{
        .timing = .manual,
        .method = .complete,
        .supports_incremental = false,
    };

    const view_id = try manager.createMaterializedView(
        "test_view",
        "MATCH (u:User) WHERE u.active = true RETURN u.name",
        refresh_strategy,
    );

    try testing.expect(view_id == 1);
    const metrics_after_create = manager.getMetrics();
    try testing.expect(metrics_after_create.total_views == 1);

    const stats = manager.getViewStatistics(view_id);
    try testing.expect(stats != null);
    try testing.expect(stats.?.refresh_count == 0);

    try manager.dropMaterializedView(view_id);

    const metrics_after_drop = manager.getMetrics();
    try testing.expect(metrics_after_drop.views_dropped == 1);
    try testing.expect(manager.getViewStatistics(view_id) == null);
}

test "Refresh strategies and methods" {
    const allocator = testing.allocator;

    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();

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

        const view_id = try manager.createMaterializedView(view_name, "MATCH (n:Node) RETURN n.id", strategy);
        try testing.expect(view_id == i + 1);
    }

    const metrics = manager.getMetrics();
    try testing.expect(metrics.total_views == 3);
}

test "View refresh updates statistics" {
    const allocator = testing.allocator;

    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();

    const view_id = try manager.createMaterializedView(
        "refresh_test_view",
        "MATCH (p:Person) WHERE p.age > 18 RETURN p",
        materialized_views.RefreshStrategy{
            .timing = .manual,
            .method = .complete,
            .supports_incremental = true,
        },
    );

    const complete_result = try manager.refreshMaterializedView(view_id, materialized_views.RefreshOptions{
        .force_complete = true,
        .priority = .high,
    });
    try testing.expect(complete_result.method == .complete);

    // Non-forced refresh follows determineOptimalRefreshMethod: small view
    // with refresh_count <= 5 takes the complete path.
    const second_result = try manager.refreshMaterializedView(view_id, materialized_views.RefreshOptions{
        .force_complete = false,
        .priority = .normal,
    });
    try testing.expect(second_result.method == .complete);

    const stats = manager.getViewStatistics(view_id).?;
    try testing.expect(stats.refresh_count == 2);

    const metrics = manager.getMetrics();
    try testing.expect(metrics.total_refreshes == 2);
    try testing.expect(metrics.successful_refreshes == 2);
}

test "Dependency tracking via handleTableChange" {
    const allocator = testing.allocator;

    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();

    const view1_id = try manager.createMaterializedView(
        "users_view",
        "MATCH (u:User) WHERE u.active = true RETURN u",
        materialized_views.RefreshStrategy{
            .timing = .auto_immediate,
            .method = .incremental,
            .supports_incremental = true,
        },
    );

    const view2_id = try manager.createMaterializedView(
        "orders_view",
        "MATCH (u:User)-[:PLACED]->(o:Order) RETURN u.id, o.total",
        materialized_views.RefreshStrategy{
            .timing = .auto_scheduled,
            .method = .complete,
        },
    );

    // Dependencies are node labels / relationship types from the MATCH
    // pattern. A change to "User" affects both views.
    const affected_rows = [_]materialized_views.RowId{ 1, 2, 3 };
    try manager.handleTableChange("User", .update, &affected_rows);

    try testing.expect(manager.getViewStatistics(view1_id) != null);
    try testing.expect(manager.getViewStatistics(view2_id) != null);

    // auto_scheduled views are marked stale on change.
    const view2 = manager.view_catalog.getView(view2_id).?;
    try testing.expect(view2.is_valid == false);
}

test "View catalog operations and listViews" {
    const allocator = testing.allocator;

    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();

    const view_names = [_][]const u8{
        "products_view",
        "customers_view",
        "analytics_view",
    };

    for (view_names) |name| {
        _ = try manager.createMaterializedView(name, "MATCH (n) RETURN count(n)", materialized_views.RefreshStrategy{
            .timing = .manual,
            .method = .complete,
        });
    }

    const view_list = try manager.listViews();
    defer allocator.free(view_list);

    try testing.expect(view_list.len == 3);
    for (view_list) |view_info| {
        try testing.expect(view_info.id > 0);
        try testing.expect(view_info.name.len > 0);
        try testing.expect(view_info.query.len > 0);
        try testing.expect(view_info.is_valid == true);
    }
}

test "Query validation rejects mutations and garbage" {
    const allocator = testing.allocator;

    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();

    const refresh_strategy = materialized_views.RefreshStrategy{
        .timing = .manual,
        .method = .complete,
    };

    // Valid read-only GQL queries succeed.
    const valid_queries = [_][]const u8{
        "MATCH (n:Node) RETURN n",
        "MATCH (p:Person) WHERE p.age > 21 RETURN p.name",
        "MATCH (a:Account)-[:OWNS]->(c:Card) RETURN a.id, c.number",
    };

    for (valid_queries, 0..) |query, i| {
        const view_name = try std.fmt.allocPrint(allocator, "valid_view_{d}", .{i});
        defer allocator.free(view_name);

        const view_id = try manager.createMaterializedView(view_name, query, refresh_strategy);
        try testing.expect(view_id > 0);
    }

    // Mutating or unparseable definitions are rejected.
    const invalid_queries = [_][]const u8{
        "MATCH (n:Node) DELETE n",
        "MATCH (n:Node) SET n.flag = true RETURN n",
        "INSERT INTO users VALUES (1, 'John')",
        "THIS IS NOT GQL AT ALL ;;;",
    };

    for (invalid_queries, 0..) |query, i| {
        const view_name = try std.fmt.allocPrint(allocator, "invalid_view_{d}", .{i});
        defer allocator.free(view_name);

        const result = manager.createMaterializedView(view_name, query, refresh_strategy);
        try testing.expectError(error.InvalidQuery, result);
    }
}

test "View metrics and statistics" {
    const allocator = testing.allocator;

    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();

    const view_id = try manager.createMaterializedView(
        "metrics_test_view",
        "MATCH (t:Transaction) WHERE t.amount > 1000 RETURN t",
        materialized_views.RefreshStrategy{
            .timing = .manual,
            .method = .complete,
        },
    );

    const refresh_options = materialized_views.RefreshOptions{
        .force_complete = true,
    };

    for (0..3) |_| {
        _ = try manager.refreshMaterializedView(view_id, refresh_options);
    }

    const view_stats = manager.getViewStatistics(view_id).?;
    try testing.expect(view_stats.refresh_count == 3);

    const global_metrics = manager.getMetrics();
    try testing.expect(global_metrics.total_views == 1);
    try testing.expect(global_metrics.total_refreshes == 3);
    try testing.expect(global_metrics.successful_refreshes == 3);
    try testing.expect(global_metrics.failed_refreshes == 0);

    try manager.dropMaterializedView(view_id);
    try testing.expect(manager.getMetrics().views_dropped == 1);
}

test "Refresh scheduler functionality" {
    const allocator = testing.allocator;

    var scheduler = try materialized_views.RefreshScheduler.init(allocator);
    defer scheduler.deinit();

    try scheduler.scheduleRefresh(1, .immediate);
    try scheduler.scheduleRefresh(2, .incremental);
    try scheduler.scheduleRefresh(3, .scheduled);

    // Earliest scheduled time pops first (immediate < incremental < scheduled).
    const next_refresh = scheduler.getNextRefresh();
    try testing.expect(next_refresh != null);
    try testing.expect(next_refresh.?.view_id == 1);
    try testing.expect(next_refresh.?.timing == .immediate);

    const second = scheduler.getNextRefresh();
    try testing.expect(second != null);
    try testing.expect(second.?.view_id == 2);

    // Cancellation removes only the targeted view's entries.
    try scheduler.scheduleRefresh(5, .immediate);
    try scheduler.cancelRefresh(3);
    const after_cancel = scheduler.getNextRefresh();
    try testing.expect(after_cancel != null);
    try testing.expect(after_cancel.?.view_id == 5);
    try testing.expect(scheduler.getNextRefresh() == null);
}

test "Memory management and cleanup" {
    const allocator = testing.allocator;

    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();

    const num_views = 50;
    var view_ids: std.ArrayList(u64) = .empty;
    defer view_ids.deinit(allocator);

    for (0..num_views) |i| {
        const view_name = try std.fmt.allocPrint(allocator, "test_view_{d}", .{i});
        defer allocator.free(view_name);

        const view_id = try manager.createMaterializedView(view_name, "MATCH (n) RETURN n LIMIT 10", materialized_views.RefreshStrategy{
            .timing = .manual,
            .method = .complete,
        });

        try view_ids.append(allocator, view_id);
    }

    try testing.expect(manager.getMetrics().total_views == num_views);

    for (view_ids.items) |view_id| {
        try manager.dropMaterializedView(view_id);
    }

    try testing.expect(manager.getMetrics().views_dropped == num_views);

    const final_list = try manager.listViews();
    defer allocator.free(final_list);
    try testing.expect(final_list.len == 0);
}

test "Dependency tracker edge cases" {
    const allocator = testing.allocator;

    var tracker = try materialized_views.DependencyTracker.init(allocator);
    defer tracker.deinit();

    // Empty dependencies
    const empty_deps = try allocator.alloc(materialized_views.Dependency, 0);
    defer allocator.free(empty_deps);
    try tracker.registerView(1, empty_deps);

    // Getting dependencies for non-existent table
    const non_existent_deps = try tracker.getDependentViews("non_existent_table");
    defer allocator.free(non_existent_deps);
    try testing.expect(non_existent_deps.len == 0);

    // Unregistering non-existent view must not crash
    tracker.unregisterView(999);

    // Multiple views depending on the same table
    const dep = materialized_views.Dependency{
        .type = .table,
        .name = try allocator.dupe(u8, "test_table"),
        .columns = try allocator.alloc([]const u8, 0),
    };
    defer {
        allocator.free(dep.name);
        allocator.free(dep.columns);
    }

    const dep_slice = [_]materialized_views.Dependency{dep};
    try tracker.registerView(2, &dep_slice);
    try tracker.registerView(3, &dep_slice);

    const dependent_views = try tracker.getDependentViews("test_table");
    defer allocator.free(dependent_views);
    try testing.expect(dependent_views.len == 2);

    // Unregister one; the other remains.
    tracker.unregisterView(2);
    const remaining = try tracker.getDependentViews("test_table");
    defer allocator.free(remaining);
    try testing.expect(remaining.len == 1);
    try testing.expect(remaining[0] == 3);
}

test "Query rewriter basic functionality" {
    const allocator = testing.allocator;

    var rewriter = try materialized_views.QueryRewriter.init(allocator);
    defer rewriter.deinit();

    var catalog = try materialized_views.ViewCatalog.init(allocator);
    defer catalog.deinit();

    // Unparseable (SQL) input never rewrites.
    {
        const rewrite = try rewriter.findApplicableViews("SELECT * FROM users WHERE active = true", &catalog);
        try testing.expect(rewrite == null);
    }

    // Valid GQL against an empty catalog never rewrites.
    {
        const rewrite = try rewriter.findApplicableViews("MATCH (n:Person) RETURN n.name", &catalog);
        try testing.expect(rewrite == null);
    }
}

// GAP-0876 base-data source: a mutable in-memory table feeding refresh.
// Mutating `visible` between refreshes models base-table writes that the
// materialized snapshot must NOT see until the next refresh.
const TestBaseTable = struct {
    names: []const []const u8,
    visible: usize,

    fn fetch(ctx: *anyopaque, view_query: []const u8, allocator: std.mem.Allocator) anyerror![]materialized_views.Row {
        _ = view_query;
        const self: *TestBaseTable = @ptrCast(@alignCast(ctx));
        const out = try allocator.alloc(materialized_views.Row, self.visible);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |row| allocator.free(row);
            allocator.free(out);
        }
        for (self.names[0..self.visible]) |name| {
            out[filled] = try allocator.dupe(u8, name);
            filled += 1;
        }
        return out;
    }
};

// CANARY: REQ=REQ-MATVIEW-REFRESH-003; FEATURE="Query Rewriting"; ASPECT=ExactMatchRewrite; STATUS=TESTED; TEST=tests/test_materialized_views_enhanced.zig; OWNER=query; UPDATED=2026-06-11
test "GAP-0876: exact-match rewrite serves results from the view snapshot" {
    const allocator = testing.allocator;

    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();

    var base = TestBaseTable{
        .names = &[_][]const u8{ "Alice", "Bob", "Carol" },
        .visible = 2,
    };
    manager.setRowSource(materialized_views.RowSource{
        .ctx = &base,
        .fetchFn = TestBaseTable.fetch,
    });

    const view_query = "MATCH (n:Person) RETURN n.name";
    const view_id = try manager.createMaterializedView("person_names", view_query, materialized_views.RefreshStrategy{
        .timing = .manual,
        .method = .complete,
    });

    // Materialize the snapshot: base currently exposes 2 rows.
    const refresh = try manager.refreshMaterializedView(view_id, materialized_views.RefreshOptions{
        .force_complete = true,
    });
    try testing.expectEqual(@as(u64, 2), refresh.rows_processed);

    // Mutate base data WITHOUT refreshing the view.
    base.visible = 3;

    // The structurally identical query rewrites to the view...
    var rewrite = (try manager.getQueryRewrite(view_query)) orelse return error.TestExpectedRewrite;
    defer rewrite.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), rewrite.applicable_views.len);
    try testing.expectEqual(view_id, rewrite.applicable_views[0].view_id);
    try testing.expect(rewrite.applicable_views[0].usage_type == .complete_replacement);
    try testing.expect(std.mem.eql(u8, rewrite.applicable_views[0].view_name, "person_names"));
    try testing.expect(rewrite.estimated_speedup > 1.0);

    // ...and the served rows come from the SNAPSHOT (2 rows), not the
    // mutated base (3 rows). This is the rewrite-served vs base-served
    // discriminator.
    const snapshot_rows = manager.fetchRewriteRows(&rewrite) orelse return error.TestExpectedRows;
    try testing.expectEqual(@as(usize, 2), snapshot_rows.len);
    try testing.expect(std.mem.eql(u8, snapshot_rows[0], "Alice"));
    try testing.expect(std.mem.eql(u8, snapshot_rows[1], "Bob"));

    // After an explicit refresh, the snapshot catches up with base.
    _ = try manager.refreshMaterializedView(view_id, materialized_views.RefreshOptions{
        .force_complete = true,
    });
    var rewrite2 = (try manager.getQueryRewrite(view_query)) orelse return error.TestExpectedRewrite;
    defer rewrite2.deinit(allocator);
    const refreshed_rows = manager.fetchRewriteRows(&rewrite2) orelse return error.TestExpectedRows;
    try testing.expectEqual(@as(usize, 3), refreshed_rows.len);
    try testing.expect(std.mem.eql(u8, refreshed_rows[2], "Carol"));
}

test "GAP-0876: non-matching queries never rewrite" {
    const allocator = testing.allocator;

    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();

    _ = try manager.createMaterializedView("person_names", "MATCH (n:Person) RETURN n.name", materialized_views.RefreshStrategy{
        .timing = .manual,
        .method = .complete,
    });

    // Different label.
    try testing.expect((try manager.getQueryRewrite("MATCH (n:Company) RETURN n.name")) == null);

    // Same label, different projection — the label-overlap heuristic that
    // used to claim complete_replacement here must NOT fire.
    try testing.expect((try manager.getQueryRewrite("MATCH (n:Person) RETURN n.age")) == null);

    // Same label + projection, different variable name (out of exact-match scope).
    try testing.expect((try manager.getQueryRewrite("MATCH (p:Person) RETURN p.name")) == null);

    // Extra WHERE clause.
    try testing.expect((try manager.getQueryRewrite("MATCH (n:Person) WHERE n.age > 30 RETURN n.name")) == null);

    // Extra LIMIT.
    try testing.expect((try manager.getQueryRewrite("MATCH (n:Person) RETURN n.name LIMIT 5")) == null);

    // Unparseable input.
    try testing.expect((try manager.getQueryRewrite("SELECT * FROM users WHERE active = true")) == null);
}

test "GAP-0876: exact match is whitespace-insensitive but structure-sensitive" {
    const allocator = testing.allocator;

    var manager = try materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();

    _ = try manager.createMaterializedView(
        "adult_names",
        "MATCH (n:Person) WHERE n.age > 18 RETURN n.name ORDER BY n.name LIMIT 10",
        materialized_views.RefreshStrategy{ .timing = .manual, .method = .complete },
    );

    // Same structure, different formatting → rewrite (comparison is on the
    // parsed AST, not on bytes).
    var rewrite = (try manager.getQueryRewrite(
        "MATCH  (n:Person)\n  WHERE n.age > 18\n  RETURN n.name\n  ORDER BY n.name\n  LIMIT 10",
    )) orelse return error.TestExpectedRewrite;
    defer rewrite.deinit(allocator);
    try testing.expect(rewrite.applicable_views[0].usage_type == .complete_replacement);

    // Different literal in WHERE → no rewrite.
    try testing.expect((try manager.getQueryRewrite(
        "MATCH (n:Person) WHERE n.age > 21 RETURN n.name ORDER BY n.name LIMIT 10",
    )) == null);

    // Different LIMIT → no rewrite.
    try testing.expect((try manager.getQueryRewrite(
        "MATCH (n:Person) WHERE n.age > 18 RETURN n.name ORDER BY n.name LIMIT 20",
    )) == null);

    // Missing ORDER BY → no rewrite.
    try testing.expect((try manager.getQueryRewrite(
        "MATCH (n:Person) WHERE n.age > 18 RETURN n.name LIMIT 10",
    )) == null);
}
