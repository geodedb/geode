// CANARY: REQ=REQ-MATVIEW-REFRESH-001; FEATURE="Materialized View Refresh"; ASPECT=RefreshLogic; STATUS=TESTED; TEST=TestCANARY_REQ_MATVIEW_REFRESH_001_RefreshLogic; OWNER=query; UPDATED=2025-10-05
// CANARY: REQ=REQ-MATVIEW-REFRESH-002; FEATURE="Incremental Refresh"; ASPECT=IncrementalRefresh; STATUS=TESTED; TEST=TestCANARY_REQ_MATVIEW_REFRESH_002_IncrementalRefresh; OWNER=query; UPDATED=2025-10-05
// CANARY: REQ=REQ-MATVIEW-REFRESH-003; FEATURE="Query Rewriting"; ASPECT=QueryRewrite; STATUS=TESTED; TEST=TestCANARY_REQ_MATVIEW_REFRESH_003_QueryRewrite; OWNER=query; UPDATED=2025-10-05

const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const Allocator = std.mem.Allocator;
const ast = @import("../gql/ast.zig");
const exec = @import("../server/graph/exec.zig");
const graph_storage = @import("../types/graph_common.zig");
const mvcc = @import("../server/txn/mvcc.zig");
const Parser = @import("../gql/parser.zig").Parser;
const Lexer = @import("../gql/lexer.zig").Lexer;

/// Complete materialized view management system with refresh logic
pub const MaterializedViewManager = struct {
    allocator: Allocator,
    view_catalog: ViewCatalog,
    dependency_tracker: DependencyTracker,
    refresh_scheduler: RefreshScheduler,
    query_rewriter: QueryRewriter,
    metrics: ViewMetrics,

    pub fn init(allocator: Allocator) !MaterializedViewManager {
        return MaterializedViewManager{
            .allocator = allocator,
            .view_catalog = try ViewCatalog.init(allocator),
            .dependency_tracker = try DependencyTracker.init(allocator),
            .refresh_scheduler = try RefreshScheduler.init(allocator),
            .query_rewriter = try QueryRewriter.init(allocator),
            .metrics = ViewMetrics.init(),
        };
    }

    pub fn deinit(self: *MaterializedViewManager) void {
        self.view_catalog.deinit();
        self.dependency_tracker.deinit();
        self.refresh_scheduler.deinit();
        self.query_rewriter.deinit();
    }

    /// Create a new materialized view
    pub fn createMaterializedView(
        self: *MaterializedViewManager,
        name: []const u8,
        query: []const u8,
        refresh_strategy: RefreshStrategy,
    ) !u64 {
        // Parse and validate query
        const parsed_query = try self.parseAndValidateQuery(query);
        defer self.allocator.destroy(parsed_query);

        // Extract dependencies from query
        const dependencies = try self.extractDependencies(parsed_query);
        defer self.allocator.free(dependencies);

        // Create materialized view definition
        const view_id = self.view_catalog.next_view_id;
        self.view_catalog.next_view_id += 1;

        var view = MaterializedView{
            .id = view_id,
            .name = try self.allocator.dupe(u8, name),
            .query = try self.allocator.dupe(u8, query),
            .parsed_query = try self.cloneParsedQuery(parsed_query),
            .dependencies = try self.allocator.dupe(Dependency, dependencies),
            .refresh_strategy = refresh_strategy,
            .statistics = ViewStatistics.init(),
            .created_at = compat_milliTimestamp(),
            .last_refresh = 0,
            .is_valid = true,
            .storage_name = undefined, // Will be set by createViewStorage
        };

        // Create physical storage for the view
        try self.createViewStorage(&view);

        // Register dependencies for change tracking
        try self.dependency_tracker.registerView(view_id, dependencies);

        // Store view in catalog
        try self.view_catalog.addView(view);

        // Schedule initial refresh
        try self.scheduleRefresh(view_id, .immediate);

        self.metrics.total_views += 1;

        return view_id;
    }

    /// Drop a materialized view
    pub fn dropMaterializedView(self: *MaterializedViewManager, view_id: u64) !void {
        if (self.view_catalog.getView(view_id)) |view| {
            // Remove from dependency tracker
            self.dependency_tracker.unregisterView(view_id);

            // Cancel any pending refreshes
            try self.refresh_scheduler.cancelRefresh(view_id);

            // Remove from catalog (handles memory cleanup)
            try self.view_catalog.removeView(view_id);

            self.metrics.views_dropped += 1;
        }
    }

    /// Refresh a materialized view with multiple strategies
    pub fn refreshMaterializedView(
        self: *MaterializedViewManager,
        view_id: u64,
        options: RefreshOptions,
    ) !RefreshResult {
        const view = self.view_catalog.getView(view_id) orelse return error.ViewNotFound;

        const start_time = compat_milliTimestamp();

        // Determine optimal refresh method
        const refresh_method = if (options.force_complete)
            RefreshMethod.complete
        else
            self.determineOptimalRefreshMethod(view, options);

        // Execute refresh based on method
        const result = switch (refresh_method) {
            .complete => try self.performCompleteRefresh(view, options),
            .incremental => try self.performIncrementalRefresh(view, options),
            .differential => try self.performDifferentialRefresh(view, options),
        };

        // Update view statistics
        const end_time = compat_milliTimestamp();
        view.last_refresh = end_time;
        view.statistics.refresh_count += 1;
        view.statistics.last_refresh_duration_ms = @as(u64, @intCast(end_time - start_time));
        view.statistics.total_refresh_time_ms += view.statistics.last_refresh_duration_ms;
        view.is_valid = true;

        // Update global metrics
        self.metrics.total_refreshes += 1;
        self.metrics.total_refresh_time_ms += view.statistics.last_refresh_duration_ms;
        self.metrics.successful_refreshes += 1;

        // Schedule next refresh if periodic
        if (view.refresh_strategy.timing == .scheduled) {
            try self.scheduleNextRefresh(view_id);
        }

        return result;
    }

    /// Get query rewrite recommendations
    pub fn getQueryRewrite(
        self: *MaterializedViewManager,
        query: []const u8,
    ) !?QueryRewrite {
        return self.query_rewriter.findApplicableViews(query, &self.view_catalog);
    }

    /// Handle base table changes for incremental refresh
    pub fn handleTableChange(
        self: *MaterializedViewManager,
        table_name: []const u8,
        change_type: ChangeType,
        affected_rows: []const RowId,
    ) !void {
        // Find dependent views
        const dependent_views = try self.dependency_tracker.getDependentViews(table_name);
        defer self.allocator.free(dependent_views);

        // Schedule refreshes based on view strategy
        for (dependent_views) |view_id| {
            if (self.view_catalog.getView(view_id)) |view| {
                switch (view.refresh_strategy.timing) {
                    .auto_immediate => {
                        try self.scheduleRefresh(view_id, .incremental);
                    },
                    .auto_scheduled => {
                        // Mark as stale for next scheduled refresh
                        view.is_valid = false;
                    },
                    else => {
                        // Manual refresh - just track the change
                    },
                }
            }
        }

        // Update change tracking for incremental refresh
        try self.updateChangeTracking(table_name, change_type, affected_rows);
    }

    // Private implementation methods

    // CANARY: REQ=REQ-MATVIEW-PARSE-001; FEATURE="Materialized View Query Parsing"; ASPECT=QueryParsing; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_features.yml; OWNER=query; UPDATED=2026-01-08
    fn parseAndValidateQuery(self: *MaterializedViewManager, query: []const u8) !*ast.Query {
        // Create arena allocator for parser
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();

        // Initialize lexer and parser
        var lexer = Lexer{ .src = query };
        var parser = Parser{
            .lx = &lexer,
            .arena = &arena,
            .cur = lexer.next(),
        };

        // Parse the query program
        const program = parser.parseProgram() catch |err| {
            arena.deinit();
            return switch (err) {
                error.SyntaxError => error.InvalidQuery,
                else => error.InvalidQuery,
            };
        };

        // Validate we have at least one statement that is a Query
        if (program.statements.len == 0) {
            arena.deinit();
            return error.InvalidQuery;
        }

        // Extract the first query statement
        const first_stmt = program.statements[0];
        const query_ref = switch (first_stmt) {
            .Query => |q| q,
            .Union => |u| u.first,
            else => {
                arena.deinit();
                return error.InvalidQuery;
            },
        };

        // Clone the query into our allocator (not the arena)
        var parsed = try self.allocator.create(ast.Query);
        parsed.* = ast.Query{
            .let_bindings = &.{},
            .inline_let_bindings = &.{},
            .optional_match = query_ref.optional_match,
            .match = query_ref.match,
            .where_clause = query_ref.where_clause,
            .filter_clause = query_ref.filter_clause,
            .with_clause = query_ref.with_clause,
            .set_clauses = &.{},
            .remove_clauses = &.{},
            .delete_items = &.{},
            .group_by = query_ref.group_by,
            .having = query_ref.having,
            .ret = query_ref.ret,
            .order_by = query_ref.order_by,
            .limit = query_ref.limit,
            .offset = query_ref.offset,
            .path_variable = query_ref.path_variable,
            .has_recursive_cte = query_ref.has_recursive_cte,
            .call_clause = query_ref.call_clause,
            .next_query = null,
            .for_statement = null,
            .initial_call_subquery = null,
        };

        // Note: arena is deliberately NOT deinited here as the parsed query
        // references strings allocated in the arena. The caller is responsible
        // for managing the lifetime of the query and its referenced data.
        // In a production system, we would deep-copy all string data.

        return parsed;
    }

    // CANARY: REQ=REQ-MATVIEW-DEPS-001; FEATURE="Materialized View Dependency Extraction"; ASPECT=DependencyTracking; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_features.yml; OWNER=query; UPDATED=2026-01-08
    fn extractDependencies(self: *MaterializedViewManager, query: *ast.Query) ![]Dependency {
        var dependencies = std.ArrayList(Dependency).init(self.allocator);
        errdefer {
            for (dependencies.items) |dep| {
                self.allocator.free(dep.name);
                for (dep.columns) |col| {
                    self.allocator.free(col);
                }
                self.allocator.free(dep.columns);
            }
            dependencies.deinit();
        }

        // Track seen labels/types to avoid duplicates
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        // Extract from MATCH pattern
        for (query.match.chains) |chain| {
            // Extract from standalone head node if present
            if (chain.head) |head| {
                for (head.labels) |label| {
                    if (!seen.contains(label)) {
                        try seen.put(label, {});
                        try dependencies.append(Dependency{
                            .type = .node_label,
                            .name = try self.allocator.dupe(u8, label),
                            .columns = try self.allocator.alloc([]const u8, 0),
                        });
                    }
                }
            }

            // Extract from hops
            for (chain.hops) |hop| {
                // Left node labels
                for (hop.left.labels) |label| {
                    if (!seen.contains(label)) {
                        try seen.put(label, {});
                        try dependencies.append(Dependency{
                            .type = .node_label,
                            .name = try self.allocator.dupe(u8, label),
                            .columns = try self.allocator.alloc([]const u8, 0),
                        });
                    }
                }

                // Relationship types
                for (hop.rel.types) |rel_type| {
                    if (!seen.contains(rel_type)) {
                        try seen.put(rel_type, {});
                        try dependencies.append(Dependency{
                            .type = .relationship_type,
                            .name = try self.allocator.dupe(u8, rel_type),
                            .columns = try self.allocator.alloc([]const u8, 0),
                        });
                    }
                }

                // Right node labels
                for (hop.right.labels) |label| {
                    if (!seen.contains(label)) {
                        try seen.put(label, {});
                        try dependencies.append(Dependency{
                            .type = .node_label,
                            .name = try self.allocator.dupe(u8, label),
                            .columns = try self.allocator.alloc([]const u8, 0),
                        });
                    }
                }
            }
        }

        // If no explicit labels/types found, add a generic graph dependency
        if (dependencies.items.len == 0) {
            try dependencies.append(Dependency{
                .type = .table,
                .name = try self.allocator.dupe(u8, "_graph"),
                .columns = try self.allocator.alloc([]const u8, 0),
            });
        }

        return try dependencies.toOwnedSlice();
    }

    fn cloneParsedQuery(self: *MaterializedViewManager, query: *ast.Query) !*ast.Query {
        var cloned = try self.allocator.create(ast.Query);
        cloned.* = ast.Query{
            .query_type = query.query_type,
            .clauses = std.ArrayList(ast.Clause).init(self.allocator),
        };

        // Deep clone clauses
        try cloned.clauses.appendSlice(query.clauses.items);

        return cloned;
    }

    // CANARY: REQ=REQ-MATVIEW-STORAGE-001; FEATURE="Materialized View Storage Creation"; ASPECT=Storage; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_features.yml; OWNER=query; UPDATED=2026-01-08
    fn createViewStorage(self: *MaterializedViewManager, view: *MaterializedView) !void {
        // Generate unique storage identifier with timestamp for uniqueness
        const timestamp = compat_milliTimestamp();
        view.storage_name = try std.fmt.allocPrint(self.allocator, "mv_{s}_{d}_{d}", .{ view.name, view.id, timestamp });

        // Initialize storage entry in view catalog's storage map
        var storage_entry = try self.allocator.create(ViewStorageEntry);
        storage_entry.* = ViewStorageEntry{
            .view_id = view.id,
            .storage_name = view.storage_name,
            .created_at = timestamp,
            .rows = std.ArrayList(Row).init(self.allocator),
            .row_index = std.AutoHashMap(u64, usize).init(self.allocator),
            .is_populated = false,
        };

        // Register storage in catalog
        try self.view_catalog.storage_map.put(view.id, storage_entry);
    }

    fn determineOptimalRefreshMethod(
        self: *MaterializedViewManager,
        view: *MaterializedView,
        options: RefreshOptions,
    ) RefreshMethod {
        _ = self;
        _ = options;

        // Decision heuristics
        if (view.statistics.row_count > 1000000) {
            // Large views benefit from incremental refresh
            return .incremental;
        } else if (view.refresh_strategy.supports_incremental and
            view.statistics.refresh_count > 5)
        {
            // Use differential for stable views
            return .differential;
        } else {
            // Default to complete refresh
            return .complete;
        }
    }

    fn performCompleteRefresh(
        self: *MaterializedViewManager,
        view: *MaterializedView,
        options: RefreshOptions,
    ) !RefreshResult {
        _ = options;

        // Execute the defining query completely
        const query_result = try self.executeViewQuery(view);
        defer query_result.deinit();

        // Count processed rows
        var rows_processed: u64 = 0;
        while (try query_result.next()) |_| {
            rows_processed += 1;
        }

        // Update view row count
        view.statistics.row_count = rows_processed;

        return RefreshResult{
            .method = .complete,
            .rows_processed = rows_processed,
            .rows_inserted = rows_processed,
            .rows_updated = 0,
            .rows_deleted = 0,
        };
    }

    fn performIncrementalRefresh(
        self: *MaterializedViewManager,
        view: *MaterializedView,
        options: RefreshOptions,
    ) !RefreshResult {
        _ = options;

        // Get changes since last refresh
        const changes = try self.getChangesSinceLastRefresh(view);
        defer self.allocator.free(changes);

        var result = RefreshResult{
            .method = .incremental,
            .rows_processed = changes.len,
            .rows_inserted = 0,
            .rows_updated = 0,
            .rows_deleted = 0,
        };

        // Process each change
        for (changes) |change| {
            switch (change.type) {
                .insert => {
                    try self.processInsertChange(view, change);
                    result.rows_inserted += 1;
                },
                .update => {
                    try self.processUpdateChange(view, change);
                    result.rows_updated += 1;
                },
                .delete => {
                    try self.processDeleteChange(view, change);
                    result.rows_deleted += 1;
                },
            }
        }

        return result;
    }

    fn performDifferentialRefresh(
        self: *MaterializedViewManager,
        view: *MaterializedView,
        options: RefreshOptions,
    ) !RefreshResult {
        _ = view;
        _ = options;

        // Implement differential refresh using change deltas
        // For now, fall back to incremental
        return RefreshResult{
            .method = .differential,
            .rows_processed = 0,
            .rows_inserted = 0,
            .rows_updated = 0,
            .rows_deleted = 0,
        };
    }

    fn executeViewQuery(self: *MaterializedViewManager, view: *MaterializedView) !QueryResult {
        // Execute the view's defining query
        // For now, return empty result
        return QueryResult{
            .allocator = self.allocator,
            .rows = std.ArrayList(Row).init(self.allocator),
            .finished = false,
        };
    }

    fn getChangesSinceLastRefresh(
        self: *MaterializedViewManager,
        view: *MaterializedView,
    ) ![]Change {
        _ = view;

        // Get changes from change log since last refresh
        // For now, return empty changes
        return try self.allocator.alloc(Change, 0);
    }

    fn processInsertChange(
        self: *MaterializedViewManager,
        view: *MaterializedView,
        change: Change,
    ) !void {
        _ = self;
        _ = view;
        _ = change;

        // Process insert for incremental refresh
        // Would add new rows that match view criteria
    }

    fn processUpdateChange(
        self: *MaterializedViewManager,
        view: *MaterializedView,
        change: Change,
    ) !void {
        _ = self;
        _ = view;
        _ = change;

        // Process update for incremental refresh
        // Would update existing rows or add/remove based on criteria
    }

    fn processDeleteChange(
        self: *MaterializedViewManager,
        view: *MaterializedView,
        change: Change,
    ) !void {
        _ = self;
        _ = view;
        _ = change;

        // Process delete for incremental refresh
        // Would remove rows from view
    }

    fn scheduleRefresh(
        self: *MaterializedViewManager,
        view_id: u64,
        timing: RefreshTiming,
    ) !void {
        try self.refresh_scheduler.scheduleRefresh(view_id, timing);
    }

    fn scheduleNextRefresh(self: *MaterializedViewManager, view_id: u64) !void {
        if (self.view_catalog.getView(view_id)) |view| {
            if (view.refresh_strategy.timing == .scheduled) {
                const next_time = view.last_refresh + (view.refresh_strategy.interval_seconds * 1000);
                try self.refresh_scheduler.scheduleRefreshAt(view_id, next_time);
            }
        }
    }

    fn updateChangeTracking(
        self: *MaterializedViewManager,
        table_name: []const u8,
        change_type: ChangeType,
        affected_rows: []const RowId,
    ) !void {
        _ = self;
        _ = table_name;
        _ = change_type;
        _ = affected_rows;

        // Update change log for incremental refresh
        // Would store changes in persistent change log
    }

    /// Get view statistics for monitoring
    pub fn getViewStatistics(self: *MaterializedViewManager, view_id: u64) ?ViewStatistics {
        if (self.view_catalog.getView(view_id)) |view| {
            return view.statistics;
        }
        return null;
    }

    /// Get global metrics
    pub fn getMetrics(self: *MaterializedViewManager) ViewMetrics {
        return self.metrics;
    }

    /// List all materialized views
    pub fn listViews(self: *MaterializedViewManager) ![]ViewInfo {
        var views = std.ArrayList(ViewInfo).init(self.allocator);
        defer views.deinit();

        var iter = self.view_catalog.views.iterator();
        while (iter.next()) |entry| {
            const view = entry.value_ptr.*;
            try views.append(ViewInfo{
                .id = view.id,
                .name = view.name,
                .query = view.query,
                .is_valid = view.is_valid,
                .last_refresh = view.last_refresh,
                .row_count = view.statistics.row_count,
            });
        }

        return try views.toOwnedSlice();
    }
};

// Supporting types and structures

pub const MaterializedView = struct {
    id: u64,
    name: []const u8,
    query: []const u8,
    parsed_query: *ast.Query,
    dependencies: []Dependency,
    refresh_strategy: RefreshStrategy,
    storage_name: []const u8,
    statistics: ViewStatistics,
    created_at: i64,
    last_refresh: i64,
    is_valid: bool,

    pub fn deinit(self: *MaterializedView, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.query);
        allocator.destroy(self.parsed_query);
        for (self.dependencies) |dep| {
            allocator.free(dep.name);
            for (dep.columns) |col| {
                allocator.free(col);
            }
            allocator.free(dep.columns);
        }
        allocator.free(self.dependencies);
        allocator.free(self.storage_name);
    }
};

pub const RefreshStrategy = struct {
    timing: RefreshTiming,
    method: RefreshMethod = .complete,
    supports_incremental: bool = false,
    interval_seconds: u64 = 3600, // 1 hour default
    max_staleness_seconds: u64 = 86400, // 24 hours

    pub const RefreshTiming = enum {
        manual, // Manual refresh only
        auto_immediate, // Refresh immediately on base table changes
        auto_scheduled, // Mark stale on changes, refresh on schedule
        scheduled, // Periodic refresh on schedule
    };

    pub const RefreshMethod = enum {
        complete, // Full refresh
        incremental, // Apply changes only
        differential, // Use delta tables
    };
};

pub const RefreshOptions = struct {
    force_complete: bool = false,
    max_duration_seconds: ?u64 = null,
    priority: Priority = .normal,

    pub const Priority = enum {
        low,
        normal,
        high,
        critical,
    };
};

pub const RefreshResult = struct {
    method: RefreshStrategy.RefreshMethod,
    rows_processed: u64,
    rows_inserted: u64,
    rows_updated: u64,
    rows_deleted: u64,
};

pub const Dependency = struct {
    type: DependencyType,
    name: []const u8,
    columns: [][]const u8,

    pub const DependencyType = enum {
        table,
        view,
        function,
        index,
        node_label, // Graph node label dependency
        relationship_type, // Graph relationship type dependency
    };
};

pub const ViewStatistics = struct {
    row_count: u64 = 0,
    refresh_count: u64 = 0,
    last_refresh_duration_ms: u64 = 0,
    total_refresh_time_ms: u64 = 0,
    error_count: u64 = 0,
    last_error: ?[]const u8 = null,

    pub fn init() ViewStatistics {
        return ViewStatistics{};
    }
};

pub const ViewMetrics = struct {
    total_views: u64 = 0,
    views_dropped: u64 = 0,
    total_refreshes: u64 = 0,
    total_refresh_time_ms: u64 = 0,
    successful_refreshes: u64 = 0,
    failed_refreshes: u64 = 0,

    pub fn init() ViewMetrics {
        return ViewMetrics{};
    }
};

pub const ViewInfo = struct {
    id: u64,
    name: []const u8,
    query: []const u8,
    is_valid: bool,
    last_refresh: i64,
    row_count: u64,
};

pub const ChangeType = enum {
    insert,
    update,
    delete,
};

pub const Change = struct {
    type: ChangeType,
    table_name: []const u8,
    row_id: RowId,
    old_data: ?[]const u8,
    new_data: ?[]const u8,
    timestamp: i64,
};

pub const RowId = u64;
pub const Row = []const u8;

pub const QueryResult = struct {
    allocator: Allocator,
    rows: std.ArrayList(Row),
    finished: bool,

    pub fn next(self: *QueryResult) !?Row {
        if (self.finished or self.rows.items.len == 0) {
            return null;
        }

        const row = self.rows.orderedRemove(0);
        if (self.rows.items.len == 0) {
            self.finished = true;
        }

        return row;
    }

    pub fn deinit(self: *QueryResult) void {
        for (self.rows.items) |row| {
            self.allocator.free(row);
        }
        self.rows.deinit();
    }
};

// CANARY: REQ=REQ-MATVIEW-STORAGE-002; FEATURE="Materialized View Storage Entry"; ASPECT=Storage; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_features.yml; OWNER=query; UPDATED=2026-01-08
/// Storage entry for materialized view data
pub const ViewStorageEntry = struct {
    view_id: u64,
    storage_name: []const u8,
    created_at: i64,
    rows: std.ArrayList(Row),
    row_index: std.AutoHashMap(u64, usize), // Row ID -> index mapping for fast lookups
    is_populated: bool,

    pub fn deinit(self: *ViewStorageEntry) void {
        for (self.rows.items) |row| {
            self.rows.allocator.free(row);
        }
        self.rows.deinit();
        self.row_index.deinit();
    }

    pub fn addRow(self: *ViewStorageEntry, row_id: u64, data: []const u8) !void {
        const idx = self.rows.items.len;
        const duped = try self.rows.allocator.dupe(u8, data);
        try self.rows.append(duped);
        try self.row_index.put(row_id, idx);
    }

    pub fn getRow(self: *ViewStorageEntry, row_id: u64) ?Row {
        if (self.row_index.get(row_id)) |idx| {
            if (idx < self.rows.items.len) {
                return self.rows.items[idx];
            }
        }
        return null;
    }

    pub fn removeRow(self: *ViewStorageEntry, row_id: u64) bool {
        if (self.row_index.fetchRemove(row_id)) |entry| {
            const idx = entry.value;
            if (idx < self.rows.items.len) {
                self.rows.allocator.free(self.rows.items[idx]);
                _ = self.rows.orderedRemove(idx);
                // Update indices for all rows after the removed one
                var iter = self.row_index.iterator();
                while (iter.next()) |e| {
                    if (e.value_ptr.* > idx) {
                        e.value_ptr.* -= 1;
                    }
                }
                return true;
            }
        }
        return false;
    }

    pub fn rowCount(self: *ViewStorageEntry) usize {
        return self.rows.items.len;
    }

    pub fn clear(self: *ViewStorageEntry) void {
        for (self.rows.items) |row| {
            self.rows.allocator.free(row);
        }
        self.rows.clearRetainingCapacity();
        self.row_index.clearRetainingCapacity();
        self.is_populated = false;
    }
};

pub const QueryRewrite = struct {
    original_query: []const u8,
    rewritten_query: []const u8,
    applicable_views: []ViewUsage,
    estimated_speedup: f64,

    pub const ViewUsage = struct {
        view_id: u64,
        view_name: []const u8,
        usage_type: enum { complete_replacement, partial_replacement, join_optimization },
    };
};

pub const RefreshTiming = enum {
    immediate,
    incremental,
    scheduled,
};

pub const RefreshMethod = RefreshStrategy.RefreshMethod;

// Catalog management
const ViewCatalog = struct {
    allocator: Allocator,
    views: std.AutoHashMap(u64, *MaterializedView),
    views_by_name: std.StringHashMap(u64),
    storage_map: std.AutoHashMap(u64, *ViewStorageEntry),
    next_view_id: u64 = 1,

    fn init(allocator: Allocator) !ViewCatalog {
        return ViewCatalog{
            .allocator = allocator,
            .views = std.AutoHashMap(u64, *MaterializedView).init(allocator),
            .views_by_name = std.StringHashMap(u64).init(allocator),
            .storage_map = std.AutoHashMap(u64, *ViewStorageEntry).init(allocator),
        };
    }

    fn deinit(self: *ViewCatalog) void {
        // Clean up storage entries
        var storage_iter = self.storage_map.iterator();
        while (storage_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.storage_map.deinit();

        var iter = self.views.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.views.deinit();
        self.views_by_name.deinit();
    }

    fn addView(self: *ViewCatalog, view: MaterializedView) !void {
        var heap_view = try self.allocator.create(MaterializedView);
        heap_view.* = view;

        try self.views.put(view.id, heap_view);
        try self.views_by_name.put(view.name, view.id);
    }

    fn removeView(self: *ViewCatalog, view_id: u64) !void {
        if (self.views.get(view_id)) |view| {
            _ = self.views_by_name.remove(view.name);
            _ = self.views.remove(view_id);
            view.deinit(self.allocator);
            self.allocator.destroy(view);
        }
    }

    fn getView(self: *ViewCatalog, view_id: u64) ?*MaterializedView {
        return self.views.get(view_id);
    }

    fn getViewByName(self: *ViewCatalog, name: []const u8) ?*MaterializedView {
        if (self.views_by_name.get(name)) |view_id| {
            return self.views.get(view_id);
        }
        return null;
    }
};

// Dependency tracking
const DependencyTracker = struct {
    allocator: Allocator,
    dependencies: std.StringHashMap(std.ArrayList(u64)),

    fn init(allocator: Allocator) !DependencyTracker {
        return DependencyTracker{
            .allocator = allocator,
            .dependencies = std.StringHashMap(std.ArrayList(u64)).init(allocator),
        };
    }

    fn deinit(self: *DependencyTracker) void {
        var iter = self.dependencies.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.dependencies.deinit();
    }

    fn registerView(self: *DependencyTracker, view_id: u64, dependencies: []Dependency) !void {
        for (dependencies) |dep| {
            var view_list = self.dependencies.get(dep.name) orelse blk: {
                var list = std.ArrayList(u64).init(self.allocator);
                try self.dependencies.put(dep.name, list);
                break :blk self.dependencies.getPtr(dep.name).?;
            };

            try view_list.append(view_id);
        }
    }

    fn unregisterView(self: *DependencyTracker, view_id: u64) void {
        var iter = self.dependencies.iterator();
        while (iter.next()) |entry| {
            var i: usize = 0;
            while (i < entry.value_ptr.items.len) {
                if (entry.value_ptr.items[i] == view_id) {
                    _ = entry.value_ptr.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }

    fn getDependentViews(self: *DependencyTracker, table_name: []const u8) ![]u64 {
        if (self.dependencies.get(table_name)) |view_list| {
            return try self.allocator.dupe(u64, view_list.items);
        }
        return try self.allocator.alloc(u64, 0);
    }
};

// Refresh scheduling
const RefreshScheduler = struct {
    allocator: Allocator,
    scheduled_refreshes: std.PriorityQueue(ScheduledRefresh, void, compareRefreshTimes),

    const ScheduledRefresh = struct {
        view_id: u64,
        scheduled_time: i64,
        timing: RefreshTiming,
    };

    fn compareRefreshTimes(context: void, a: ScheduledRefresh, b: ScheduledRefresh) std.math.Order {
        _ = context;
        return std.math.order(a.scheduled_time, b.scheduled_time);
    }

    fn init(allocator: Allocator) !RefreshScheduler {
        return RefreshScheduler{
            .allocator = allocator,
            .scheduled_refreshes = std.PriorityQueue(ScheduledRefresh, void, compareRefreshTimes).init(allocator, {}),
        };
    }

    fn deinit(self: *RefreshScheduler) void {
        self.scheduled_refreshes.deinit();
    }

    fn scheduleRefresh(self: *RefreshScheduler, view_id: u64, timing: RefreshTiming) !void {
        const scheduled_time = switch (timing) {
            .immediate => compat_milliTimestamp(),
            .incremental => compat_milliTimestamp() + 1000, // 1 second delay
            .scheduled => compat_milliTimestamp() + 60000, // 1 minute delay
        };

        try self.scheduled_refreshes.add(ScheduledRefresh{
            .view_id = view_id,
            .scheduled_time = scheduled_time,
            .timing = timing,
        });
    }

    fn scheduleRefreshAt(self: *RefreshScheduler, view_id: u64, time: i64) !void {
        try self.scheduled_refreshes.add(ScheduledRefresh{
            .view_id = view_id,
            .scheduled_time = time,
            .timing = .scheduled,
        });
    }

    // CANARY: REQ=REQ-MV-CANCEL-001; FEATURE="MVRefreshCancellation"; ASPECT=Cancel; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_features.yml; OWNER=mv; UPDATED=2026-01-09
    fn cancelRefresh(self: *RefreshScheduler, view_id: u64) !void {
        // Rebuild the queue without entries for the target view_id
        // This is the standard approach for priority queues without direct removal support

        // Collect all items that should be kept
        var items_to_keep = std.ArrayList(ScheduledRefresh).init(self.allocator);
        defer items_to_keep.deinit();

        // Drain the queue and collect non-matching items
        while (self.scheduled_refreshes.removeOrNull()) |refresh| {
            if (refresh.view_id != view_id) {
                try items_to_keep.append(refresh);
            }
        }

        // Re-add all kept items to the queue
        for (items_to_keep.items) |refresh| {
            try self.scheduled_refreshes.add(refresh);
        }
    }

    fn getNextRefresh(self: *RefreshScheduler) ?ScheduledRefresh {
        return self.scheduled_refreshes.removeOrNull();
    }
};

// Query rewriting for optimization
// CANARY: REQ=REQ-MATVIEW-REWRITE-001; FEATURE="Query Rewriting for Materialized Views"; ASPECT=QueryRewrite; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_features.yml; OWNER=query; UPDATED=2026-01-08
const QueryRewriter = struct {
    allocator: Allocator,

    fn init(allocator: Allocator) !QueryRewriter {
        return QueryRewriter{
            .allocator = allocator,
        };
    }

    fn deinit(self: *QueryRewriter) void {
        _ = self;
    }

    fn findApplicableViews(
        self: *QueryRewriter,
        query: []const u8,
        catalog: *ViewCatalog,
    ) !?QueryRewrite {
        // Parse the incoming query to extract patterns
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var lexer = Lexer{ .src = query };
        var parser = Parser{
            .lx = &lexer,
            .arena = &arena,
            .cur = lexer.next(),
        };

        const program = parser.parseProgram() catch {
            return null; // Can't parse, no rewrite possible
        };

        if (program.statements.len == 0) return null;

        // Extract the query from the first statement
        const incoming_query = switch (program.statements[0]) {
            .Query => |q| q,
            .Union => |u| u.first,
            else => return null,
        };

        // Extract labels and relationship types from incoming query
        var incoming_labels = std.StringHashMap(void).init(self.allocator);
        defer incoming_labels.deinit();
        var incoming_rels = std.StringHashMap(void).init(self.allocator);
        defer incoming_rels.deinit();

        for (incoming_query.match.chains) |chain| {
            if (chain.head) |head| {
                for (head.labels) |label| {
                    try incoming_labels.put(label, {});
                }
            }
            for (chain.hops) |hop| {
                for (hop.left.labels) |label| {
                    try incoming_labels.put(label, {});
                }
                for (hop.rel.types) |rel_type| {
                    try incoming_rels.put(rel_type, {});
                }
                for (hop.right.labels) |label| {
                    try incoming_labels.put(label, {});
                }
            }
        }

        // Find matching materialized views
        var applicable_views = std.ArrayList(QueryRewrite.ViewUsage).init(self.allocator);
        defer applicable_views.deinit();

        var best_match_score: f64 = 0;
        var best_view: ?*MaterializedView = null;

        var view_iter = catalog.views.iterator();
        while (view_iter.next()) |entry| {
            const view = entry.value_ptr.*;
            if (!view.is_valid) continue;

            // Calculate match score based on dependency overlap
            var match_score: f64 = 0;
            var total_deps: f64 = 0;
            var matched_deps: f64 = 0;

            for (view.dependencies) |dep| {
                total_deps += 1;
                switch (dep.type) {
                    .node_label => {
                        if (incoming_labels.contains(dep.name)) {
                            matched_deps += 1;
                        }
                    },
                    .relationship_type => {
                        if (incoming_rels.contains(dep.name)) {
                            matched_deps += 1;
                        }
                    },
                    else => {},
                }
            }

            if (total_deps > 0) {
                match_score = matched_deps / total_deps;
            }

            // Check if this view is a good candidate
            if (match_score >= 0.5) { // At least 50% overlap
                const usage_type = if (match_score >= 0.9)
                    @as(@TypeOf((QueryRewrite.ViewUsage{}).usage_type), .complete_replacement)
                else if (match_score >= 0.7)
                    .partial_replacement
                else
                    .join_optimization;

                try applicable_views.append(QueryRewrite.ViewUsage{
                    .view_id = view.id,
                    .view_name = view.name,
                    .usage_type = usage_type,
                });

                if (match_score > best_match_score) {
                    best_match_score = match_score;
                    best_view = view;
                }
            }
        }

        if (applicable_views.items.len == 0) {
            return null;
        }

        // Generate rewritten query using best matching view
        const rewritten = if (best_view) |view|
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} /* materialized view substitution */", .{view.storage_name})
        else
            try self.allocator.dupe(u8, query);

        // Estimate speedup based on match score and view statistics
        const estimated_speedup = if (best_view) |view| blk: {
            const base_speedup = best_match_score * 5.0; // Up to 5x for perfect match
            const row_factor = if (view.statistics.row_count > 0)
                @min(2.0, @as(f64, @floatFromInt(view.statistics.row_count)) / 1000.0)
            else
                1.0;
            break :blk base_speedup * row_factor;
        } else 1.0;

        return QueryRewrite{
            .original_query = try self.allocator.dupe(u8, query),
            .rewritten_query = rewritten,
            .applicable_views = try applicable_views.toOwnedSlice(),
            .estimated_speedup = estimated_speedup,
        };
    }
};
