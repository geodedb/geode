// CANARY: REQ=REQ-MATVIEW-REFRESH-001; FEATURE="Materialized View Refresh"; ASPECT=RefreshLogic; STATUS=TESTED; TEST=tests/test_materialized_views_enhanced.zig; OWNER=query; UPDATED=2026-06-11
// CANARY: REQ=REQ-MATVIEW-REFRESH-002; FEATURE="Incremental Refresh"; ASPECT=IncrementalRefresh; STATUS=IMPL; TEST=tests/test_materialized_views_enhanced.zig; OWNER=query; UPDATED=2026-06-11
// CANARY: REQ=REQ-MATVIEW-REFRESH-003; FEATURE="Query Rewriting"; ASPECT=QueryRewrite; STATUS=TESTED; TEST=tests/test_materialized_views_enhanced.zig; OWNER=query; UPDATED=2026-06-11
//
// GAP-0876 (2026-06-11): the query-rewrite path implements EXACT-MATCH
// rewrite only — an incoming query that is structurally identical to a
// view's definition (same MATCH pattern, same WHERE, same RETURN
// projection, same ORDER BY/LIMIT/OFFSET) is answered from the view's
// materialized snapshot. The previous label-overlap scoring heuristic was
// removed: it claimed `complete_replacement` for queries that merely
// shared a node label with a view (e.g. `RETURN n.age` against a view
// projecting `n.name`), which is a wrong answer, not an optimization.
// Cost-based partial rewrite and automatic executor integration are
// future work; this manager is NOT yet consulted by the execution path
// (see docs/MATERIALIZED_VIEWS.md).

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

const Allocator = std.mem.Allocator;
const ast = @import("../gql/ast.zig");
const Parser = @import("../gql/parser.zig").Parser;
const Lexer = @import("../gql/lexer.zig").Lexer;
// GAP-0810: optional shared AST cache surface (mirrors Task 1.3 wiring in
// `src/query/materialized_views.zig`). See `setAstCache()` below.
const lib = @import("../lib.zig");

/// Pluggable base-data source for view materialization. The enhanced
/// manager is a standalone subsystem (not wired into the executor), so the
/// owner supplies the function that evaluates a view's defining query
/// against real base data. `fetchFn` must return a slice of rows, each
/// allocated with `allocator`; the caller takes ownership of both the
/// slice and the rows.
pub const RowSource = struct {
    ctx: *anyopaque,
    fetchFn: *const fn (ctx: *anyopaque, view_query: []const u8, allocator: Allocator) anyerror![]Row,
};

/// Complete materialized view management system with refresh logic
pub const MaterializedViewManager = struct {
    allocator: Allocator,
    view_catalog: ViewCatalog,
    dependency_tracker: DependencyTracker,
    refresh_scheduler: RefreshScheduler,
    query_rewriter: QueryRewriter,
    metrics: ViewMetrics,
    // GAP-0876: base-data seam used by refresh to materialize rows into
    // view storage. Null means refreshes materialize zero rows (the
    // manager has no executor wiring of its own).
    row_source: ?RowSource = null,
    // GAP-0810: optional shared AST cache. When wired by the server via
    // `setAstCache()`, scope-bounded parses (currently the query-rewrite
    // path in `QueryRewriter.findApplicableViews`) route through
    // `lib.parseGqlCached` so identical incoming-query shapes amortize the
    // parser cost. Null means "no cache -- fall back to the direct
    // Parser/Lexer path", which preserves every existing standalone caller
    // (tests, shell, benches).
    // CANARY: REQ=REQ-PERF-QPS-0810; FEATURE="SharedAstCache"; ASPECT=EnhancedViewWiring; STATUS=IMPL; TEST=tests/test_gap0810_cross_subsystem_cache.zig; OWNER=performance; UPDATED=2026-04-20
    ast_cache: ?*lib.SharedAstCache = null,

    pub fn init(allocator: Allocator) !MaterializedViewManager {
        return MaterializedViewManager{
            .allocator = allocator,
            .view_catalog = try ViewCatalog.init(allocator),
            .dependency_tracker = try DependencyTracker.init(allocator),
            .refresh_scheduler = try RefreshScheduler.init(allocator),
            .query_rewriter = try QueryRewriter.init(allocator),
            .metrics = ViewMetrics.init(),
            .row_source = null,
            .ast_cache = null,
        };
    }

    /// GAP-0810: wire a process-wide shared AST cache into the enhanced
    /// view manager. The server is expected to call this at startup with
    /// `ServerState.shared_ast_cache` so query-rewrite parses reuse handles
    /// across refresh cycles and across subsystems (QUIC handler,
    /// distributed coordinator, classic view manager). Pass null to
    /// disable; cache lifetime must outlive the manager.
    ///
    /// Note: at the time of writing (2026-04-20) the enhanced manager is
    /// not yet constructed anywhere in `src/server/*`, so this hook is
    /// present-but-dormant in production. See
    /// `docs/performance/2026-04-20-query-bench/enhanced-manager-cache-note.md`
    /// for the disposition.
    pub fn setAstCache(self: *MaterializedViewManager, cache: ?*lib.SharedAstCache) void {
        self.ast_cache = cache;
        // Propagate into the nested rewriter -- that's the only parse
        // callsite here with a scope-bounded lifetime that's safe to cache.
        self.query_rewriter.ast_cache = cache;
    }

    /// GAP-0876: wire the base-data source used by refresh to materialize
    /// rows into view storage. Source lifetime must outlive the manager.
    pub fn setRowSource(self: *MaterializedViewManager, source: ?RowSource) void {
        self.row_source = source;
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
        // Parse and validate the defining query in a scope-bounded arena.
        // The AST is only needed here for validation + dependency
        // extraction (which deep-copies what it keeps); nothing retains
        // arena-backed references past this function.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed_query = try parseViewDefinition(&arena, query);

        // Extract dependencies from query (names are duped into
        // self.allocator; ownership transfers to the view below).
        const dependencies = try self.extractDependencies(&parsed_query);
        errdefer freeDependencies(self.allocator, dependencies);

        // Create materialized view definition
        const view_id = self.view_catalog.next_view_id;
        self.view_catalog.next_view_id += 1;

        var view = MaterializedView{
            .id = view_id,
            .name = try self.allocator.dupe(u8, name),
            .query = try self.allocator.dupe(u8, query),
            .dependencies = dependencies,
            .refresh_strategy = refresh_strategy,
            .statistics = ViewStatistics.init(),
            .created_at = compat_milliTimestamp(),
            .last_refresh = 0,
            .is_valid = true,
            .storage_name = undefined, // Will be set by createViewStorage
        };
        errdefer {
            self.allocator.free(view.name);
            self.allocator.free(view.query);
        }

        // Create physical storage for the view
        try self.createViewStorage(&view);

        // Register dependencies for change tracking
        try self.dependency_tracker.registerView(view_id, dependencies);

        // Store view in catalog (catalog takes ownership of all view
        // allocations from here on).
        try self.view_catalog.addView(view);

        // Schedule initial refresh
        try self.scheduleRefresh(view_id, .immediate);

        self.metrics.total_views += 1;

        return view_id;
    }

    /// Drop a materialized view
    pub fn dropMaterializedView(self: *MaterializedViewManager, view_id: u64) !void {
        if (self.view_catalog.getView(view_id)) |_| {
            // Remove from dependency tracker
            self.dependency_tracker.unregisterView(view_id);

            // Cancel any pending refreshes
            try self.refresh_scheduler.cancelRefresh(view_id);

            // Drop the materialized snapshot (must happen before
            // removeView frees view.storage_name, which the storage entry
            // borrows).
            if (self.view_catalog.storage_map.fetchRemove(view_id)) |kv| {
                kv.value.deinit();
                self.allocator.destroy(kv.value);
            }

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

    /// Get query rewrite recommendations. Returns non-null ONLY when a
    /// valid view's definition is structurally identical to the incoming
    /// query (GAP-0876 exact-match rewrite). Caller owns the returned
    /// QueryRewrite and must call `deinit` on it.
    pub fn getQueryRewrite(
        self: *MaterializedViewManager,
        query: []const u8,
    ) !?QueryRewrite {
        return self.query_rewriter.findApplicableViews(query, &self.view_catalog);
    }

    /// GAP-0876: serve the materialized snapshot for an exact-match
    /// rewrite. Returns the view's rows (borrowed; valid until the next
    /// refresh or drop of that view), or null when the rewrite does not
    /// name a populated complete-replacement view.
    pub fn fetchRewriteRows(self: *MaterializedViewManager, rewrite: *const QueryRewrite) ?[]const Row {
        for (rewrite.applicable_views) |usage| {
            if (usage.usage_type == .complete_replacement) {
                if (self.getViewRows(usage.view_id)) |rows| return rows;
            }
        }
        return null;
    }

    /// Borrowed view snapshot rows (valid until next refresh/drop), or
    /// null when the view does not exist or has never been populated.
    pub fn getViewRows(self: *MaterializedViewManager, view_id: u64) ?[]const Row {
        const storage = self.view_catalog.storage_map.get(view_id) orelse return null;
        if (!storage.is_populated) return null;
        return storage.rows.items;
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

    // CANARY: REQ=REQ-MATVIEW-PARSE-001; FEATURE="Materialized View Query Parsing"; ASPECT=QueryParsing; STATUS=TESTED; TEST=tests/test_materialized_views_enhanced.zig; OWNER=query; UPDATED=2026-06-11
    /// Parse + validate a view definition inside the caller's arena. The
    /// returned Query references arena memory and must not outlive it.
    fn parseViewDefinition(arena: *std.heap.ArenaAllocator, query: []const u8) !ast.Query {
        var lexer = Lexer{ .src = query };
        var parser = Parser{
            .lx = &lexer,
            .arena = arena,
            .cur = lexer.next(),
        };

        const program = parser.parseProgram() catch {
            return error.InvalidQuery;
        };

        if (program.statements.len == 0) return error.InvalidQuery;

        const query_ref = switch (program.statements[0]) {
            .Query => |q| q,
            .Union => |u| u.first,
            else => return error.InvalidQuery,
        };

        // A materialized view definition must be read-only.
        if (query_ref.set_clauses.len != 0 or
            query_ref.remove_clauses.len != 0 or
            query_ref.delete_items.len != 0 or
            query_ref.create_pattern != null or
            query_ref.merge_statement != null)
        {
            return error.InvalidQuery;
        }

        return query_ref;
    }

    // CANARY: REQ=REQ-MATVIEW-DEPS-001; FEATURE="Materialized View Dependency Extraction"; ASPECT=DependencyTracking; STATUS=TESTED; TEST=tests/test_materialized_views_enhanced.zig; OWNER=query; UPDATED=2026-06-11
    fn extractDependencies(self: *MaterializedViewManager, query: *const ast.Query) ![]Dependency {
        var dependencies: std.ArrayList(Dependency) = .empty;
        errdefer {
            for (dependencies.items) |dep| {
                self.allocator.free(dep.name);
                for (dep.columns) |col| {
                    self.allocator.free(col);
                }
                self.allocator.free(dep.columns);
            }
            dependencies.deinit(self.allocator);
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
                        try dependencies.append(self.allocator, Dependency{
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
                        try dependencies.append(self.allocator, Dependency{
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
                        try dependencies.append(self.allocator, Dependency{
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
                        try dependencies.append(self.allocator, Dependency{
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
            try dependencies.append(self.allocator, Dependency{
                .type = .table,
                .name = try self.allocator.dupe(u8, "_graph"),
                .columns = try self.allocator.alloc([]const u8, 0),
            });
        }

        return try dependencies.toOwnedSlice(self.allocator);
    }

    fn freeDependencies(allocator: Allocator, dependencies: []Dependency) void {
        for (dependencies) |dep| {
            allocator.free(dep.name);
            for (dep.columns) |col| {
                allocator.free(col);
            }
            allocator.free(dep.columns);
        }
        allocator.free(dependencies);
    }

    // CANARY: REQ=REQ-MATVIEW-STORAGE-001; FEATURE="Materialized View Storage Creation"; ASPECT=Storage; STATUS=TESTED; TEST=tests/test_materialized_views_enhanced.zig; OWNER=query; UPDATED=2026-06-11
    fn createViewStorage(self: *MaterializedViewManager, view: *MaterializedView) !void {
        // Generate unique storage identifier with timestamp for uniqueness
        const timestamp = compat_milliTimestamp();
        view.storage_name = try std.fmt.allocPrint(self.allocator, "mv_{s}_{d}_{d}", .{ view.name, view.id, timestamp });
        errdefer self.allocator.free(view.storage_name);

        // Initialize storage entry in view catalog's storage map
        const storage_entry = try self.allocator.create(ViewStorageEntry);
        errdefer self.allocator.destroy(storage_entry);
        storage_entry.* = ViewStorageEntry{
            .allocator = self.allocator,
            .view_id = view.id,
            .storage_name = view.storage_name,
            .created_at = timestamp,
            .rows = .empty,
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
        var query_result = try self.executeViewQuery(view);
        defer query_result.deinit();

        // GAP-0876: materialize the result into the view's storage so the
        // snapshot can serve exact-match rewrites.
        const storage = self.view_catalog.storage_map.get(view.id) orelse return error.ViewStorageMissing;
        storage.clear();

        var rows_processed: u64 = 0;
        while (try query_result.next()) |row| {
            // addRow dupes; we own the popped row and must free it.
            defer self.allocator.free(row);
            try storage.addRow(rows_processed, row);
            rows_processed += 1;
        }
        storage.is_populated = true;

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
        _ = self;
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
        // GAP-0876: evaluate the defining query through the wired base-data
        // source. Without a source the manager has no executor of its own,
        // so the result is empty (documented limitation).
        if (self.row_source) |source| {
            const fetched = try source.fetchFn(source.ctx, view.query, self.allocator);
            defer self.allocator.free(fetched);
            var rows: std.ArrayList(Row) = .empty;
            errdefer {
                for (rows.items) |r| self.allocator.free(r);
                rows.deinit(self.allocator);
            }
            try rows.appendSlice(self.allocator, fetched);
            return QueryResult{
                .allocator = self.allocator,
                .rows = rows,
                .finished = false,
            };
        }

        return QueryResult{
            .allocator = self.allocator,
            .rows = .empty,
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
                const next_time = view.last_refresh + @as(i64, @intCast(view.refresh_strategy.interval_seconds * 1000));
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
        var views: std.ArrayList(ViewInfo) = .empty;
        defer views.deinit(self.allocator);

        var iter = self.view_catalog.views.iterator();
        while (iter.next()) |entry| {
            const view = entry.value_ptr.*;
            try views.append(self.allocator, ViewInfo{
                .id = view.id,
                .name = view.name,
                .query = view.query,
                .is_valid = view.is_valid,
                .last_refresh = view.last_refresh,
                .row_count = view.statistics.row_count,
            });
        }

        return try views.toOwnedSlice(self.allocator);
    }
};

// Supporting types and structures

pub const MaterializedView = struct {
    id: u64,
    name: []const u8,
    query: []const u8,
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
    timing: Timing,
    method: Method = .complete,
    supports_incremental: bool = false,
    interval_seconds: u64 = 3600, // 1 hour default
    max_staleness_seconds: u64 = 86400, // 24 hours

    pub const Timing = enum {
        manual, // Manual refresh only
        auto_immediate, // Refresh immediately on base table changes
        auto_scheduled, // Mark stale on changes, refresh on schedule
        scheduled, // Periodic refresh on schedule
    };
    // Back-compat alias; the unqualified name would be ambiguous with the
    // file-level scheduler RefreshTiming inside this namespace.
    pub const RefreshTiming = Timing;

    pub const Method = enum {
        complete, // Full refresh
        incremental, // Apply changes only
        differential, // Use delta tables
    };
    pub const RefreshMethod = Method;
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
        self.rows.deinit(self.allocator);
    }
};

// CANARY: REQ=REQ-MATVIEW-STORAGE-002; FEATURE="Materialized View Storage Entry"; ASPECT=Storage; STATUS=TESTED; TEST=tests/test_materialized_views_enhanced.zig; OWNER=query; UPDATED=2026-06-11
/// Storage entry for materialized view data
pub const ViewStorageEntry = struct {
    allocator: Allocator,
    view_id: u64,
    storage_name: []const u8,
    created_at: i64,
    rows: std.ArrayList(Row),
    row_index: std.AutoHashMap(u64, usize), // Row ID -> index mapping for fast lookups
    is_populated: bool,

    pub fn deinit(self: *ViewStorageEntry) void {
        for (self.rows.items) |row| {
            self.allocator.free(row);
        }
        self.rows.deinit(self.allocator);
        self.row_index.deinit();
    }

    pub fn addRow(self: *ViewStorageEntry, row_id: u64, data: []const u8) !void {
        const idx = self.rows.items.len;
        const duped = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(duped);
        try self.rows.append(self.allocator, duped);
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
                self.allocator.free(self.rows.items[idx]);
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
            self.allocator.free(row);
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

    pub const UsageType = enum { complete_replacement, partial_replacement, join_optimization };

    pub const ViewUsage = struct {
        view_id: u64,
        view_name: []const u8,
        usage_type: UsageType,
    };

    pub fn deinit(self: *QueryRewrite, allocator: Allocator) void {
        allocator.free(self.original_query);
        allocator.free(self.rewritten_query);
        for (self.applicable_views) |usage| {
            allocator.free(usage.view_name);
        }
        allocator.free(self.applicable_views);
    }
};

pub const RefreshTiming = enum {
    immediate,
    incremental,
    scheduled,
};

pub const RefreshMethod = RefreshStrategy.RefreshMethod;

// Catalog management
pub const ViewCatalog = struct {
    allocator: Allocator,
    views: std.AutoHashMap(u64, *MaterializedView),
    views_by_name: std.StringHashMap(u64),
    storage_map: std.AutoHashMap(u64, *ViewStorageEntry),
    next_view_id: u64 = 1,

    pub fn init(allocator: Allocator) !ViewCatalog {
        return ViewCatalog{
            .allocator = allocator,
            .views = std.AutoHashMap(u64, *MaterializedView).init(allocator),
            .views_by_name = std.StringHashMap(u64).init(allocator),
            .storage_map = std.AutoHashMap(u64, *ViewStorageEntry).init(allocator),
        };
    }

    pub fn deinit(self: *ViewCatalog) void {
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

    pub fn addView(self: *ViewCatalog, view: MaterializedView) !void {
        const heap_view = try self.allocator.create(MaterializedView);
        heap_view.* = view;

        try self.views.put(view.id, heap_view);
        try self.views_by_name.put(heap_view.name, view.id);
    }

    pub fn removeView(self: *ViewCatalog, view_id: u64) !void {
        if (self.views.get(view_id)) |view| {
            _ = self.views_by_name.remove(view.name);
            _ = self.views.remove(view_id);
            view.deinit(self.allocator);
            self.allocator.destroy(view);
        }
    }

    pub fn getView(self: *ViewCatalog, view_id: u64) ?*MaterializedView {
        return self.views.get(view_id);
    }

    pub fn getViewByName(self: *ViewCatalog, name: []const u8) ?*MaterializedView {
        if (self.views_by_name.get(name)) |view_id| {
            return self.views.get(view_id);
        }
        return null;
    }
};

// Dependency tracking
pub const DependencyTracker = struct {
    allocator: Allocator,
    // Keys are owned (duped) so they cannot dangle after a view (and its
    // dependency names) is dropped.
    dependencies: std.StringHashMap(std.ArrayList(u64)),

    pub fn init(allocator: Allocator) !DependencyTracker {
        return DependencyTracker{
            .allocator = allocator,
            .dependencies = std.StringHashMap(std.ArrayList(u64)).init(allocator),
        };
    }

    pub fn deinit(self: *DependencyTracker) void {
        var iter = self.dependencies.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.dependencies.deinit();
    }

    pub fn registerView(self: *DependencyTracker, view_id: u64, dependencies: []const Dependency) !void {
        for (dependencies) |dep| {
            const gop = try self.dependencies.getOrPut(dep.name);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.allocator.dupe(u8, dep.name);
                gop.value_ptr.* = .empty;
            }
            try gop.value_ptr.append(self.allocator, view_id);
        }
    }

    pub fn unregisterView(self: *DependencyTracker, view_id: u64) void {
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

    pub fn getDependentViews(self: *DependencyTracker, table_name: []const u8) ![]u64 {
        if (self.dependencies.get(table_name)) |view_list| {
            return try self.allocator.dupe(u64, view_list.items);
        }
        return try self.allocator.alloc(u64, 0);
    }
};

// Refresh scheduling
pub const RefreshScheduler = struct {
    allocator: Allocator,
    scheduled_refreshes: std.PriorityQueue(ScheduledRefresh, void, compareRefreshTimes),

    pub const ScheduledRefresh = struct {
        view_id: u64,
        scheduled_time: i64,
        timing: RefreshTiming,
    };

    fn compareRefreshTimes(context: void, a: ScheduledRefresh, b: ScheduledRefresh) std.math.Order {
        _ = context;
        return std.math.order(a.scheduled_time, b.scheduled_time);
    }

    pub fn init(allocator: Allocator) !RefreshScheduler {
        return RefreshScheduler{
            .allocator = allocator,
            .scheduled_refreshes = std.PriorityQueue(ScheduledRefresh, void, compareRefreshTimes).initContext({}),
        };
    }

    pub fn deinit(self: *RefreshScheduler) void {
        self.scheduled_refreshes.deinit(self.allocator);
    }

    pub fn scheduleRefresh(self: *RefreshScheduler, view_id: u64, timing: RefreshTiming) !void {
        const scheduled_time = switch (timing) {
            .immediate => compat_milliTimestamp(),
            .incremental => compat_milliTimestamp() + 1000, // 1 second delay
            .scheduled => compat_milliTimestamp() + 60000, // 1 minute delay
        };

        try self.scheduled_refreshes.push(self.allocator, ScheduledRefresh{
            .view_id = view_id,
            .scheduled_time = scheduled_time,
            .timing = timing,
        });
    }

    pub fn scheduleRefreshAt(self: *RefreshScheduler, view_id: u64, time: i64) !void {
        try self.scheduled_refreshes.push(self.allocator, ScheduledRefresh{
            .view_id = view_id,
            .scheduled_time = time,
            .timing = .scheduled,
        });
    }

    // CANARY: REQ=REQ-MV-CANCEL-001; FEATURE="MVRefreshCancellation"; ASPECT=Cancel; STATUS=TESTED; TEST=tests/test_materialized_views_enhanced.zig; OWNER=mv; UPDATED=2026-06-11
    pub fn cancelRefresh(self: *RefreshScheduler, view_id: u64) !void {
        // Rebuild the queue without entries for the target view_id
        // This is the standard approach for priority queues without direct removal support

        // Collect all items that should be kept
        var items_to_keep: std.ArrayList(ScheduledRefresh) = .empty;
        defer items_to_keep.deinit(self.allocator);

        // Drain the queue and collect non-matching items
        while (self.scheduled_refreshes.pop()) |refresh| {
            if (refresh.view_id != view_id) {
                try items_to_keep.append(self.allocator, refresh);
            }
        }

        // Re-add all kept items to the queue
        for (items_to_keep.items) |refresh| {
            try self.scheduled_refreshes.push(self.allocator, refresh);
        }
    }

    pub fn getNextRefresh(self: *RefreshScheduler) ?ScheduledRefresh {
        return self.scheduled_refreshes.pop();
    }
};

// Query rewriting for optimization
// CANARY: REQ=REQ-MATVIEW-REWRITE-001; FEATURE="Query Rewriting for Materialized Views"; ASPECT=QueryRewrite; STATUS=TESTED; TEST=tests/test_materialized_views_enhanced.zig; OWNER=query; UPDATED=2026-06-11
/// GAP-0876: exact-match query rewriter. A rewrite is produced ONLY when
/// the incoming query is structurally identical to a valid view's
/// definition (same MATCH pattern, WHERE, RETURN projection, ORDER
/// BY/LIMIT/OFFSET). Anything else returns null — no label-overlap
/// heuristics, no partial rewrites. Cost-based partial rewrite is future
/// work.
pub const QueryRewriter = struct {
    allocator: Allocator,
    // GAP-0810: same optional cache surface as `MaterializedViewManager`;
    // wired via `MaterializedViewManager.setAstCache()`. Null preserves
    // the existing arena-backed parse path.
    ast_cache: ?*lib.SharedAstCache = null,

    pub fn init(allocator: Allocator) !QueryRewriter {
        return QueryRewriter{
            .allocator = allocator,
            .ast_cache = null,
        };
    }

    pub fn deinit(self: *QueryRewriter) void {
        _ = self;
    }

    pub fn findApplicableViews(
        self: *QueryRewriter,
        query: []const u8,
        catalog: *ViewCatalog,
    ) !?QueryRewrite {
        // GAP-0810: when the server has wired a shared AST cache, route
        // through it so identical incoming-query shapes amortize the
        // parser cost. This parse site is scope-bounded -- both branches
        // read `incoming_query` only within this function, which is why
        // it's safe to release the cache handle (or deinit the arena) at
        // end of scope. The returned `QueryRewrite` deep-copies everything
        // it retains.
        if (self.ast_cache) |cache| {
            const outcome = lib.parseGqlCached(cache, query, .{}) catch {
                return null;
            };
            var handle = switch (outcome) {
                .Err => return null,
                .Ok => |h| h,
            };
            defer handle.release();

            const program = handle.parse_result.program;
            if (program.statements.len == 0) return null;
            const incoming_query = switch (program.statements[0]) {
                .Query => |q| q,
                .Union => |u| u.first,
                else => return null,
            };
            return try self.buildRewriteForQuery(query, &incoming_query, catalog);
        }

        // Fallback: arena-backed direct parse (preserves behavior for
        // every existing caller that hasn't called `setAstCache`).
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

        return try self.buildRewriteForQuery(query, &incoming_query, catalog);
    }

    // Shared body used by both the cached and uncached parse branches
    // above. Both branches release their parse result at end of scope
    // AFTER this helper returns, so the `incoming_query` argument and
    // `query` byte slice remain valid for the full duration. The
    // `QueryRewrite` returned deep-copies everything it retains -- it does
    // NOT keep references into the parse result or the catalog.
    fn buildRewriteForQuery(
        self: *QueryRewriter,
        query: []const u8,
        incoming_query: *const ast.Query,
        catalog: *ViewCatalog,
    ) !?QueryRewrite {
        var view_iter = catalog.views.iterator();
        while (view_iter.next()) |entry| {
            const view = entry.value_ptr.*;
            if (!view.is_valid) continue;

            // Parse the view's definition in a scope-bounded arena and
            // compare structurally against the incoming query.
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            var lexer = Lexer{ .src = view.query };
            var parser = Parser{
                .lx = &lexer,
                .arena = &arena,
                .cur = lexer.next(),
            };
            const program = parser.parseProgram() catch continue;
            if (program.statements.len == 0) continue;
            const view_query = switch (program.statements[0]) {
                .Query => |q| q,
                else => continue,
            };

            if (!queriesStructurallyEqual(incoming_query, &view_query)) continue;

            // Exact match: the view answers this query completely.
            var usages = try self.allocator.alloc(QueryRewrite.ViewUsage, 1);
            errdefer self.allocator.free(usages);
            usages[0] = QueryRewrite.ViewUsage{
                .view_id = view.id,
                .view_name = try self.allocator.dupe(u8, view.name),
                .usage_type = .complete_replacement,
            };
            errdefer self.allocator.free(usages[0].view_name);

            const original = try self.allocator.dupe(u8, query);
            errdefer self.allocator.free(original);
            const rewritten = try std.fmt.allocPrint(
                self.allocator,
                "/* exact-match materialized view rewrite */ SCAN VIEW {s}",
                .{view.storage_name},
            );

            // Heuristic speedup estimate: serving precomputed rows skips
            // re-execution entirely (nominal 5x), with a bounded bonus
            // factor for larger snapshots where re-execution would cost
            // proportionally more.
            const row_factor: f64 = @max(1.0, @min(2.0, @as(f64, @floatFromInt(view.statistics.row_count)) / 1000.0));
            const estimated_speedup: f64 = 5.0 * row_factor;

            return QueryRewrite{
                .original_query = original,
                .rewritten_query = rewritten,
                .applicable_views = usages,
                .estimated_speedup = estimated_speedup,
            };
        }

        return null;
    }
};

// GAP-0876 structural comparison helpers. Conservative by construction:
// any AST construct outside the supported whitelist makes the comparison
// return false (no rewrite) rather than guessing.

fn queriesStructurallyEqual(a: *const ast.Query, b: *const ast.Query) bool {
    if (!queryIsSimpleShape(a) or !queryIsSimpleShape(b)) return false;
    if (a.optional_match != b.optional_match) return false;
    if (!graphPatternsEqual(&a.match, &b.match)) return false;
    if (!optionalExprsEqual(a.where_clause, b.where_clause)) return false;
    if (a.ret.distinct != b.ret.distinct) return false;
    if (a.ret.items.len != b.ret.items.len) return false;
    for (a.ret.items, b.ret.items) |ia, ib| {
        if (!optionalStringsEqual(ia.alias, ib.alias)) return false;
        if (!exprsEqual(&ia.expr, &ib.expr)) return false;
    }
    if (!orderBysEqual(a.order_by, b.order_by)) return false;
    if (a.limit != b.limit) return false;
    if (a.offset != b.offset) return false;
    return true;
}

/// Whitelist: only plain MATCH/WHERE/RETURN/ORDER BY/LIMIT/OFFSET queries
/// participate in exact-match rewrite. Everything else (WITH, CTEs,
/// UNWIND, CALL, chaining, grouping, parameters, ...) is out of scope.
fn queryIsSimpleShape(q: *const ast.Query) bool {
    return q.let_bindings.len == 0 and
        q.inline_let_bindings.len == 0 and
        q.unwind_clause == null and
        q.create_pattern == null and
        q.filter_clause == null and
        q.with_clause == null and
        q.cte_list == null and
        q.set_clauses.len == 0 and
        q.remove_clauses.len == 0 and
        q.delete_items.len == 0 and
        q.group_by == null and
        q.having == null and
        q.limit_param == null and
        q.offset_param == null and
        q.path_variable == null and
        !q.has_recursive_cte and
        q.call_clause == null and
        q.next_query == null and
        q.for_statement == null and
        q.initial_call_subquery == null and
        q.merge_statement == null;
}

fn graphPatternsEqual(a: *const ast.GraphPattern, b: *const ast.GraphPattern) bool {
    if (a.chains.len != b.chains.len) return false;
    for (a.chains, b.chains) |ca, cb| {
        if (!chainsEqual(&ca, &cb)) return false;
    }
    return true;
}

fn chainsEqual(a: *const ast.Chain, b: *const ast.Chain) bool {
    if (!optionalStringsEqual(a.name, b.name)) return false;
    if (a.is_shortest != b.is_shortest) return false;
    if (a.is_optional != b.is_optional) return false;
    if (a.path_mode != b.path_mode) return false;
    if ((a.head == null) != (b.head == null)) return false;
    if (a.head != null and !nodePatternsEqual(&a.head.?, &b.head.?)) return false;
    if (a.hops.len != b.hops.len) return false;
    for (a.hops, b.hops) |ha, hb| {
        if (!nodePatternsEqual(&ha.left, &hb.left)) return false;
        if (!relPatternsEqual(&ha.rel, &hb.rel)) return false;
        if (!nodePatternsEqual(&ha.right, &hb.right)) return false;
    }
    return true;
}

fn nodePatternsEqual(a: *const ast.NodePattern, b: *const ast.NodePattern) bool {
    if (!optionalStringsEqual(a.name, b.name)) return false;
    if (a.labels.len != b.labels.len) return false;
    for (a.labels, b.labels) |la, lb| {
        if (!std.mem.eql(u8, la, lb)) return false;
    }
    return propertiesEqual(a.props, b.props);
}

fn relPatternsEqual(a: *const ast.RelPattern, b: *const ast.RelPattern) bool {
    if (!optionalStringsEqual(a.name, b.name)) return false;
    if (a.dir != b.dir) return false;
    if (a.min_len != b.min_len) return false;
    if (a.max_len != b.max_len) return false;
    if (a.types.len != b.types.len) return false;
    for (a.types, b.types) |ta, tb| {
        if (!std.mem.eql(u8, ta, tb)) return false;
    }
    return propertiesEqual(a.props, b.props);
}

fn propertiesEqual(a: ?[]ast.Property, b: ?[]ast.Property) bool {
    if ((a == null) != (b == null)) return false;
    if (a == null) return true;
    if (a.?.len != b.?.len) return false;
    for (a.?, b.?) |pa, pb| {
        if (!std.mem.eql(u8, pa.key, pb.key)) return false;
        if (!exprsEqual(pa.value, pb.value)) return false;
    }
    return true;
}

fn orderBysEqual(a: ?ast.OrderBy, b: ?ast.OrderBy) bool {
    if ((a == null) != (b == null)) return false;
    if (a == null) return true;
    const oa = a.?;
    const ob = b.?;
    if (oa.keys.len != ob.keys.len) return false;
    for (oa.keys, ob.keys) |ka, kb| {
        if (ka.desc != kb.desc) return false;
        if (ka.nulls != kb.nulls) return false;
        if (!exprsEqual(&ka.expr, &kb.expr)) return false;
    }
    return true;
}

fn optionalExprsEqual(a: ?ast.Expr, b: ?ast.Expr) bool {
    if ((a == null) != (b == null)) return false;
    if (a == null) return true;
    return exprsEqual(&a.?, &b.?);
}

fn optionalStringsEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if ((a == null) != (b == null)) return false;
    if (a == null) return true;
    return std.mem.eql(u8, a.?, b.?);
}

/// Conservative expression equality over a whitelist of node kinds that
/// covers the simple-projection shape (identifiers, property accesses,
/// literals, unary/binary operators, function calls). Unsupported kinds
/// compare unequal so they can never produce a false rewrite.
fn exprsEqual(a: *const ast.Expr, b: *const ast.Expr) bool {
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
    return switch (a.*) {
        .Ident => |ia| std.mem.eql(u8, ia.orig, b.Ident.orig),
        .PropertyAccess => |pa| std.mem.eql(u8, pa.object, b.PropertyAccess.object) and
            std.mem.eql(u8, pa.property, b.PropertyAccess.property),
        .Member => |m| std.mem.eql(u8, m.field, b.Member.field) and
            exprsEqual(m.target, b.Member.target),
        .String => |s| std.mem.eql(u8, s, b.String),
        .Int => |i| i == b.Int,
        .Bool => |v| v == b.Bool,
        .Null => true,
        .DoubleLit => |d| d == b.DoubleLit,
        .Unary => |u| u.op == b.Unary.op and exprsEqual(u.expr, b.Unary.expr),
        .Binary => |bin| bin.op == b.Binary.op and
            exprsEqual(bin.left, b.Binary.left) and
            exprsEqual(bin.right, b.Binary.right),
        .Call => |c| blk: {
            const bc = b.Call;
            if (c.args.len != bc.args.len) break :blk false;
            if (!exprsEqual(c.callee, bc.callee)) break :blk false;
            for (c.args, bc.args) |arg_a, arg_b| {
                if (!exprsEqual(arg_a, arg_b)) break :blk false;
            }
            break :blk true;
        },
        .IsNull => |n| n.negated == b.IsNull.negated and exprsEqual(n.target, b.IsNull.target),
        .HasLabel => |h| std.mem.eql(u8, h.node, b.HasLabel.node) and
            std.mem.eql(u8, h.label, b.HasLabel.label),
        else => false, // Unsupported expression kinds never exact-match.
    };
}
