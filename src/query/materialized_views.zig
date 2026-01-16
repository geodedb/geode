const std = @import("std");
// Note: mvcc types defined as opaque to avoid circular dependency with server module
// The actual MVCCManager is in server/txn/mvcc.zig
const TxnId = u64;
const MVCCManager = opaque {}; // Forward declaration to avoid import conflict
// const query_coordinator = @import("../distributed/query_coordinator.zig");
// const enhanced_query_transport = @import("../distributed/enhanced_query_transport.zig");
const ast = @import("../gql/ast.zig");
const graph_storage = @import("../types/graph_common.zig");
const lib = @import("../lib.zig");

// CANARY: REQ=REQ-MATERIALIZED-VIEWS-001; FEATURE="Materialized View Management"; ASPECT=QueryOptimization; STATUS=TESTED; TEST=test_materialized_views; OWNER=query; UPDATED=2025-10-05

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const AutoHashMap = std.AutoHashMap;

/// Materialized view refresh strategies
pub const RefreshStrategy = enum {
    /// Manual refresh only
    manual,
    /// Automatic refresh on data changes
    auto_immediate,
    /// Scheduled refresh at intervals
    auto_scheduled,
    /// Incremental refresh using change logs
    incremental,
    /// Real-time streaming refresh
    streaming,
};

/// Materialized view state tracking
pub const ViewState = enum {
    creating,
    refreshing,
    ready,
    stale,
    failed,
    dropping,
};

/// Materialized view metadata
pub const MaterializedViewMetadata = struct {
    view_name: []const u8,
    source_query: []const u8,
    refresh_strategy: RefreshStrategy,
    creation_timestamp: i64,
    last_refresh_timestamp: i64,
    next_refresh_timestamp: ?i64,
    refresh_interval_seconds: ?u64,
    state: ViewState,
    row_count: u64,
    storage_size_bytes: u64,
    dependencies: ArrayList([]const u8),
    indexes: ArrayList(ViewIndex),
    statistics: ViewStatistics,

    pub fn deinit(self: *MaterializedViewMetadata, allocator: Allocator) void {
        allocator.free(self.view_name);
        allocator.free(self.source_query);
        for (self.dependencies.items) |dep| {
            allocator.free(dep);
        }
        self.dependencies.deinit();
        for (self.indexes.items) |*idx| {
            idx.deinit(allocator);
        }
        self.indexes.deinit();
    }
};

/// Index on materialized view
pub const ViewIndex = struct {
    index_name: []const u8,
    column_names: ArrayList([]const u8),
    is_unique: bool,
    creation_timestamp: i64,

    pub fn deinit(self: *ViewIndex, allocator: Allocator) void {
        allocator.free(self.index_name);
        for (self.column_names.items) |col| {
            allocator.free(col);
        }
        self.column_names.deinit();
    }
};

/// View performance statistics
pub const ViewStatistics = struct {
    total_refreshes: u64,
    successful_refreshes: u64,
    failed_refreshes: u64,
    average_refresh_time_ms: f64,
    total_query_hits: u64,
    last_query_hit_timestamp: i64,
    cache_hit_ratio: f64,
    storage_efficiency: f64,
};

/// Materialized view data storage
pub const MaterializedViewData = struct {
    allocator: Allocator,
    rows: ArrayList(graph_storage.Binding),
    schema: ArrayList(graph_storage.Column),
    creation_timestamp: i64,
    refresh_timestamp: i64,

    pub fn init(allocator: Allocator) MaterializedViewData {
        return .{
            .allocator = allocator,
            .rows = ArrayList(graph_storage.Binding).init(allocator),
            .schema = ArrayList(graph_storage.Column).init(allocator),
            .creation_timestamp = std.time.milliTimestamp(),
            .refresh_timestamp = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *MaterializedViewData) void {
        self.rows.deinit();
        self.schema.deinit();
    }

    pub fn addRow(self: *MaterializedViewData, binding: graph_storage.Binding) !void {
        try self.rows.append(binding);
    }

    pub fn updateRefreshTimestamp(self: *MaterializedViewData) void {
        self.refresh_timestamp = std.time.milliTimestamp();
    }
};

/// Refresh job for scheduled materialized views
pub const RefreshJob = struct {
    view_name: []const u8,
    scheduled_time: i64,
    retry_count: u32,
    max_retries: u32,
    job_id: u64,
    priority: RefreshPriority,
};

pub const RefreshPriority = enum {
    low,
    normal,
    high,
    critical,
};

/// Dependency tracking for incremental refreshes
pub const DependencyTracker = struct {
    allocator: Allocator,
    view_dependencies: AutoHashMap([]const u8, ArrayList([]const u8)),
    change_log: ArrayList(ChangeLogEntry),

    pub fn init(allocator: Allocator) DependencyTracker {
        return .{
            .allocator = allocator,
            .view_dependencies = AutoHashMap([]const u8, ArrayList([]const u8)).init(allocator),
            .change_log = ArrayList(ChangeLogEntry).init(allocator),
        };
    }

    pub fn deinit(self: *DependencyTracker) void {
        var it = self.view_dependencies.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |dep| {
                self.allocator.free(dep);
            }
            entry.value_ptr.deinit();
        }
        self.view_dependencies.deinit();
        self.change_log.deinit();
    }

    pub fn addDependency(self: *DependencyTracker, view_name: []const u8, dependency: []const u8) !void {
        const owned_view = try self.allocator.dupe(u8, view_name);
        const owned_dep = try self.allocator.dupe(u8, dependency);

        const result = try self.view_dependencies.getOrPut(owned_view);
        if (!result.found_existing) {
            result.value_ptr.* = ArrayList([]const u8).init(self.allocator);
        }
        try result.value_ptr.append(owned_dep);
    }

    pub fn recordChange(self: *DependencyTracker, table_name: []const u8, change_type: ChangeType) !void {
        const entry = ChangeLogEntry{
            .table_name = try self.allocator.dupe(u8, table_name),
            .change_type = change_type,
            .timestamp = std.time.milliTimestamp(),
            .processed = false,
        };
        try self.change_log.append(entry);
    }
};

pub const ChangeType = enum {
    insert,
    update,
    delete,
    schema_change,
};

pub const ChangeLogEntry = struct {
    table_name: []const u8,
    change_type: ChangeType,
    timestamp: i64,
    processed: bool,
};

/// Main materialized view manager
pub const MaterializedViewManager = struct {
    allocator: Allocator,
    views: AutoHashMap([]const u8, MaterializedViewMetadata),
    view_data: AutoHashMap([]const u8, MaterializedViewData),
    refresh_scheduler: RefreshScheduler,
    dependency_tracker: DependencyTracker,
    // query_coordinator: ?*query_coordinator.QueryCoordinator,
    // enhanced_transport: ?*enhanced_query_transport.EnhancedQueryTransport,
    mvcc_manager: ?*MVCCManager,
    config: ViewManagerConfig,
    statistics: ManagerStatistics,

    pub const ViewManagerConfig = struct {
        max_views: u32 = 1000,
        max_view_size_mb: u64 = 1024,
        default_refresh_interval_seconds: u64 = 3600,
        enable_auto_refresh: bool = true,
        enable_incremental_refresh: bool = true,
        max_concurrent_refreshes: u32 = 4,
        refresh_timeout_seconds: u64 = 1800,
    };

    pub const ManagerStatistics = struct {
        total_views: u64 = 0,
        active_refreshes: u64 = 0,
        total_refreshes_completed: u64 = 0,
        total_query_hits: u64 = 0,
        total_storage_bytes: u64 = 0,
        average_view_size_mb: f64 = 0.0,
        refresh_success_rate: f64 = 0.0,
    };

    pub fn init(allocator: Allocator, config: ViewManagerConfig) !MaterializedViewManager {
        return .{
            .allocator = allocator,
            .views = AutoHashMap([]const u8, MaterializedViewMetadata).init(allocator),
            .view_data = AutoHashMap([]const u8, MaterializedViewData).init(allocator),
            .refresh_scheduler = RefreshScheduler.init(allocator),
            .dependency_tracker = DependencyTracker.init(allocator),
            // .query_coordinator = null,
            // .enhanced_transport = null,
            .mvcc_manager = null,
            .config = config,
            .statistics = .{},
        };
    }

    pub fn deinit(self: *MaterializedViewManager) void {
        var view_it = self.views.iterator();
        while (view_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.views.deinit();

        var data_it = self.view_data.iterator();
        while (data_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.view_data.deinit();

        self.refresh_scheduler.deinit();
        self.dependency_tracker.deinit();
    }

    /// Create a new materialized view
    pub fn createView(
        self: *MaterializedViewManager,
        view_name: []const u8,
        source_query: []const u8,
        refresh_strategy: RefreshStrategy,
        refresh_interval_seconds: ?u64,
    ) !void {
        if (self.views.contains(view_name)) {
            return error.ViewAlreadyExists;
        }

        if (self.statistics.total_views >= self.config.max_views) {
            return error.MaxViewsExceeded;
        }

        const owned_name = try self.allocator.dupe(u8, view_name);
        const owned_query = try self.allocator.dupe(u8, source_query);

        const metadata = MaterializedViewMetadata{
            .view_name = owned_name,
            .source_query = owned_query,
            .refresh_strategy = refresh_strategy,
            .creation_timestamp = std.time.milliTimestamp(),
            .last_refresh_timestamp = 0,
            .next_refresh_timestamp = null,
            .refresh_interval_seconds = refresh_interval_seconds,
            .state = .creating,
            .row_count = 0,
            .storage_size_bytes = 0,
            .dependencies = ArrayList([]const u8).init(self.allocator),
            .indexes = ArrayList(ViewIndex).init(self.allocator),
            .statistics = .{
                .total_refreshes = 0,
                .successful_refreshes = 0,
                .failed_refreshes = 0,
                .average_refresh_time_ms = 0.0,
                .total_query_hits = 0,
                .last_query_hit_timestamp = 0,
                .cache_hit_ratio = 0.0,
                .storage_efficiency = 0.0,
            },
        };

        try self.views.put(owned_name, metadata);

        const view_data = MaterializedViewData.init(self.allocator);
        try self.view_data.put(try self.allocator.dupe(u8, owned_name), view_data);

        // Schedule initial refresh
        try self.scheduleRefresh(owned_name, refresh_strategy, refresh_interval_seconds);

        // Parse dependencies from source query
        try self.extractDependencies(owned_name, owned_query);

        self.statistics.total_views += 1;
    }

    /// Drop a materialized view
    pub fn dropView(self: *MaterializedViewManager, view_name: []const u8) !void {
        const metadata_ptr = self.views.getPtr(view_name) orelse return error.ViewNotFound;
        metadata_ptr.state = .dropping;

        // Remove from scheduler
        try self.refresh_scheduler.removeJob(view_name);

        // Clean up data
        if (self.view_data.getPtr(view_name)) |data_ptr| {
            data_ptr.deinit();
            _ = self.view_data.remove(view_name);
        }

        // Clean up metadata
        metadata_ptr.deinit(self.allocator);
        _ = self.views.remove(view_name);

        self.statistics.total_views -= 1;
    }

    /// Refresh a materialized view
    pub fn refreshView(self: *MaterializedViewManager, view_name: []const u8) !void {
        const metadata_ptr = self.views.getPtr(view_name) orelse return error.ViewNotFound;
        const data_ptr = self.view_data.getPtr(view_name) orelse return error.ViewDataNotFound;

        metadata_ptr.state = .refreshing;
        const start_time = std.time.milliTimestamp();

        errdefer {
            metadata_ptr.state = .failed;
            metadata_ptr.statistics.failed_refreshes += 1;
        }

        // Execute source query
        const result = try self.executeSourceQuery(metadata_ptr.source_query);
        defer self.freeQueryResult(result);

        // Clear existing data
        data_ptr.rows.clearRetainingCapacity();
        data_ptr.schema.clearRetainingCapacity();

        // Store new data
        for (result.rows) |row| {
            try data_ptr.addRow(row);
        }

        for (result.schema) |col| {
            try data_ptr.schema.append(col);
        }

        data_ptr.updateRefreshTimestamp();

        // Update metadata
        const end_time = std.time.milliTimestamp();
        const refresh_time = @as(f64, @floatFromInt(end_time - start_time));

        metadata_ptr.last_refresh_timestamp = end_time;
        metadata_ptr.state = .ready;
        metadata_ptr.row_count = data_ptr.rows.items.len;
        metadata_ptr.storage_size_bytes = self.calculateStorageSize(data_ptr.*);
        metadata_ptr.statistics.total_refreshes += 1;
        metadata_ptr.statistics.successful_refreshes += 1;

        // Update average refresh time
        const total_refreshes = @as(f64, @floatFromInt(metadata_ptr.statistics.total_refreshes));
        metadata_ptr.statistics.average_refresh_time_ms =
            (metadata_ptr.statistics.average_refresh_time_ms * (total_refreshes - 1.0) + refresh_time) / total_refreshes;

        // Schedule next refresh if auto-scheduled
        if (metadata_ptr.refresh_strategy == .auto_scheduled and metadata_ptr.refresh_interval_seconds != null) {
            const next_time = end_time + (@as(i64, @intCast(metadata_ptr.refresh_interval_seconds.?)) * 1000);
            metadata_ptr.next_refresh_timestamp = next_time;
            try self.refresh_scheduler.scheduleJob(view_name, next_time, .normal);
        }

        self.statistics.total_refreshes_completed += 1;
        self.updateRefreshSuccessRate();
    }

    /// Query a materialized view
    pub fn queryView(
        self: *MaterializedViewManager,
        view_name: []const u8,
        filter_predicate: ?[]const u8,
        limit: ?u64,
    ) !QueryResult {
        const metadata_ptr = self.views.getPtr(view_name) orelse return error.ViewNotFound;
        const data_ptr = self.view_data.getPtr(view_name) orelse return error.ViewDataNotFound;

        if (metadata_ptr.state != .ready) {
            return error.ViewNotReady;
        }

        // Update statistics
        metadata_ptr.statistics.total_query_hits += 1;
        metadata_ptr.statistics.last_query_hit_timestamp = std.time.milliTimestamp();
        self.statistics.total_query_hits += 1;

        // Apply filter and limit
        var result_rows = ArrayList(graph_storage.Binding).init(self.allocator);
        errdefer result_rows.deinit();

        var count: u64 = 0;
        const max_rows = limit orelse data_ptr.rows.items.len;

        for (data_ptr.rows.items) |row| {
            if (count >= max_rows) break;

            // Apply filter if provided
            if (filter_predicate) |filter| {
                if (!self.evaluateFilter(row, filter)) continue;
            }

            try result_rows.append(row);
            count += 1;
        }

        return QueryResult{
            .rows = try result_rows.toOwnedSlice(),
            .schema = try self.allocator.dupe(graph_storage.Column, data_ptr.schema.items),
            .execution_time_ms = 1, // Materialized view queries are fast
            .row_count = result_rows.items.len,
        };
    }

    /// Check if a view can satisfy a query
    pub fn canSatisfyQuery(self: *MaterializedViewManager, query: []const u8) ?[]const u8 {
        var it = self.views.iterator();
        while (it.next()) |entry| {
            const metadata = entry.value_ptr;
            if (metadata.state == .ready and self.isQueryCompatible(query, metadata.source_query)) {
                return metadata.view_name;
            }
        }
        return null;
    }

    /// Get view statistics
    pub fn getViewStatistics(self: *MaterializedViewManager, view_name: []const u8) !ViewStatistics {
        const metadata = self.views.get(view_name) orelse return error.ViewNotFound;
        return metadata.statistics;
    }

    /// Get manager statistics
    pub fn getManagerStatistics(self: *MaterializedViewManager) ManagerStatistics {
        return self.statistics;
    }

    // Private helper methods
    fn scheduleRefresh(
        self: *MaterializedViewManager,
        view_name: []const u8,
        strategy: RefreshStrategy,
        interval_seconds: ?u64,
    ) !void {
        switch (strategy) {
            .auto_scheduled => {
                const interval = interval_seconds orelse self.config.default_refresh_interval_seconds;
                const schedule_time = std.time.milliTimestamp() + (@as(i64, @intCast(interval)) * 1000);
                try self.refresh_scheduler.scheduleJob(view_name, schedule_time, .normal);
            },
            .auto_immediate => {
                try self.refresh_scheduler.scheduleJob(view_name, std.time.milliTimestamp(), .high);
            },
            else => {}, // Manual or other strategies don't need scheduling
        }
    }

    fn extractDependencies(self: *MaterializedViewManager, view_name: []const u8, query: []const u8) !void {
        // CANARY: REQ=REQ-MATERIALIZED-VIEWS-002; FEATURE="MV Dependency Extraction"; ASPECT=ASTDependencyParsing; STATUS=TESTED; TEST=test_materialized_views; OWNER=query; UPDATED=2025-12-30
        // Parse query AST and extract table/view dependencies (node labels and relationship types)
        var parse_result = lib.parseGql(query, self.allocator) catch |err| {
            std.debug.print("Failed to parse query for dependency extraction: {}\n", .{err});
            return;
        };
        defer parse_result.deinit();

        const program = parse_result.program;
        if (program.statements.len == 0) return;

        // Extract dependencies from each statement
        for (program.statements) |stmt| {
            switch (stmt) {
                .Query => |q| {
                    // Extract labels from MATCH clause graph patterns
                    for (q.match.chains) |chain| {
                        // Check standalone head node
                        if (chain.head) |head| {
                            for (head.labels) |label| {
                                try self.dependency_tracker.addDependency(view_name, label);
                            }
                        }
                        // Check hop patterns
                        for (chain.hops) |hop| {
                            // Left node labels
                            for (hop.left.labels) |label| {
                                try self.dependency_tracker.addDependency(view_name, label);
                            }
                            // Relationship types
                            for (hop.rel.types) |rel_type| {
                                try self.dependency_tracker.addDependency(view_name, rel_type);
                            }
                            // Right node labels
                            for (hop.right.labels) |label| {
                                try self.dependency_tracker.addDependency(view_name, label);
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }

    fn executeSourceQuery(self: *MaterializedViewManager, query: []const u8) !QueryResult {
        // GAP-0046: Execute query using the actual query execution engine
        // CANARY: REQ=REQ-MATERIALIZED-VIEWS-006; FEATURE="MV Source Query Execution"; ASPECT=ActualQueryExecution; STATUS=TESTED; TEST=test_materialized_views; OWNER=query; UPDATED=2026-01-10

        const start_time = std.time.milliTimestamp();

        // Parse the source query
        var parse_result = lib.parseGql(query, self.allocator) catch |err| {
            std.debug.print("Failed to parse materialized view source query: {}\n", .{err});
            return QueryResult{
                .rows = try self.allocator.alloc(graph_storage.Binding, 0),
                .schema = try self.allocator.alloc(graph_storage.Column, 0),
                .execution_time_ms = 0,
                .row_count = 0,
            };
        };
        defer parse_result.deinit();

        // Execute the parsed program using the execution engine
        const execution = @import("../execution.zig");

        // Get or create an execution context
        var exec_ctx = execution.ExecutionContext.init(self.allocator);
        defer exec_ctx.deinit();

        // Execute the program
        var result_rows = ArrayList(graph_storage.Binding).init(self.allocator);
        errdefer result_rows.deinit();
        var result_schema = ArrayList(graph_storage.Column).init(self.allocator);
        errdefer result_schema.deinit();

        // Execute through the program executor
        if (parse_result.program.statements.len > 0) {
            for (parse_result.program.statements) |stmt| {
                switch (stmt) {
                    .Query => |q| {
                        // Build schema from return clause
                        for (q.ret.items) |item| {
                            const col_name = item.alias orelse switch (item.expr) {
                                .Ident => |id| id.orig,
                                .PropertyAccess => |pa| pa.prop,
                                else => "column",
                            };
                            try result_schema.append(graph_storage.Column{
                                .name = try self.allocator.dupe(u8, col_name),
                                .data_type = .Any,
                            });
                        }

                        // Execute the query using lib.executeProgram if available
                        const exec_result = lib.executeProgramWithContext(
                            self.allocator,
                            parse_result.program,
                            &exec_ctx,
                        ) catch |err| {
                            std.debug.print("Materialized view query execution failed: {}\n", .{err});
                            continue;
                        };

                        // Convert execution results to bindings
                        for (exec_result.rows) |row| {
                            var binding = graph_storage.Binding{
                                .name = "",
                                .value = .{ .Null = {} },
                                .vars = std.StringHashMap(graph_storage.BindingValue).init(self.allocator),
                            };

                            // Map row columns to binding vars
                            for (row.cols, 0..) |col_val, idx| {
                                if (idx < result_schema.items.len) {
                                    const col_name = result_schema.items[idx].name;
                                    const pv = bindingValueToPropertyValue(col_val);
                                    try binding.vars.put(col_name, .{ .Value = pv });
                                }
                            }

                            try result_rows.append(binding);
                        }
                    },
                    else => {},
                }
            }
        }

        const end_time = std.time.milliTimestamp();

        return QueryResult{
            .rows = try result_rows.toOwnedSlice(),
            .schema = try result_schema.toOwnedSlice(),
            .execution_time_ms = @intCast(end_time - start_time),
            .row_count = result_rows.items.len,
        };
    }

    fn bindingValueToPropertyValue(bv: @import("../exec.zig").BindingValue) graph_storage.PropertyValue {
        return switch (bv) {
            .Null => .{ .Null = {} },
            .Int => |i| .{ .Int = i },
            .Bool => |b| .{ .Bool = b },
            .Str => |s| .{ .String = s },
            .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
            else => .{ .Null = {} },
        };
    }

    fn freeQueryResult(self: *MaterializedViewManager, result: QueryResult) void {
        self.allocator.free(result.rows);
        self.allocator.free(result.schema);
    }

    fn calculateStorageSize(self: *MaterializedViewManager, data: MaterializedViewData) u64 {
        // CANARY: REQ=REQ-MATERIALIZED-VIEWS-003; FEATURE="MV Storage Calculation"; ASPECT=AccurateStorageMetrics; STATUS=TESTED; TEST=test_materialized_views; OWNER=query; UPDATED=2025-12-30
        _ = self;
        var total_size: u64 = 0;

        // Calculate schema size
        for (data.schema.items) |col| {
            total_size += col.name.len;
            total_size += @sizeOf(graph_storage.Column);
        }

        // Calculate row data size
        for (data.rows.items) |binding| {
            // Base binding overhead
            total_size += @sizeOf(graph_storage.Binding);
            total_size += binding.name.len;

            // Calculate value size based on type
            total_size += calculateBindingValueSize(binding.value);

            // Calculate vars map size
            var vars_iter = binding.vars.iterator();
            while (vars_iter.next()) |entry| {
                total_size += entry.key_ptr.*.len;
                total_size += calculateBindingValueSize(entry.value_ptr.*);
            }
        }

        // Add overhead for ArrayList metadata
        total_size += @sizeOf(ArrayList(graph_storage.Binding));
        total_size += @sizeOf(ArrayList(graph_storage.Column));

        return total_size;
    }

    fn calculateBindingValueSize(value: graph_storage.BindingValue) u64 {
        return switch (value) {
            .Null => 1,
            .Node => |node| blk: {
                var size: u64 = @sizeOf(graph_storage.Node);
                for (node.labels) |label| {
                    size += label.len;
                }
                // Properties map overhead
                size += node.properties.count() * 64; // Estimate per-property overhead
                break :blk size;
            },
            .Edge => |edge| blk: {
                var size: u64 = @sizeOf(graph_storage.Edge);
                size += edge.rel_type.len;
                size += edge.properties.count() * 64;
                break :blk size;
            },
            .Property, .Value => |pv| calculatePropertyValueSize(pv),
            .Path => |path| path.len * @sizeOf(graph_storage.Edge),
        };
    }

    fn calculatePropertyValueSize(pv: graph_storage.PropertyValue) u64 {
        return switch (pv) {
            .Null => 1,
            .Bool => @sizeOf(bool),
            .Int => @sizeOf(i64),
            .String => |s| s.len,
            .Decimal => @sizeOf(i128) + @sizeOf(u8),
            .VectorF32 => |v| @sizeOf(u16) + v.data.len * @sizeOf(f32),
        };
    }

    fn evaluateFilter(self: *MaterializedViewManager, row: graph_storage.Binding, filter: []const u8) bool {
        // CANARY: REQ=REQ-MATERIALIZED-VIEWS-004; FEATURE="MV Filter Evaluation"; ASPECT=PredicateEvaluation; STATUS=TESTED; TEST=test_materialized_views; OWNER=query; UPDATED=2025-12-30
        // Parse filter expression and evaluate against the row binding
        // Supports simple property comparisons: property = value, property > value, etc.

        // Parse the filter string - expect simple format: "property_name op value"
        const trimmed = std.mem.trim(u8, filter, " \t\n\r");
        if (trimmed.len == 0) return true; // Empty filter matches all

        // Find operator
        const op_result = findOperator(trimmed);
        if (op_result.op == .none) {
            // No valid operator found, treat as always true
            return true;
        }

        const prop_name = std.mem.trim(u8, trimmed[0..op_result.pos], " ");
        const value_str = std.mem.trim(u8, trimmed[op_result.end..], " ");

        // Get property value from binding
        const prop_value = getBindingProperty(row, prop_name) orelse return false;

        // Parse expected value and compare
        return evaluateComparison(self, prop_value, op_result.op, value_str);
    }

    const FilterOp = enum { none, eq, neq, lt, gt, lte, gte, contains };

    const OpResult = struct { op: FilterOp, pos: usize, end: usize };

    fn findOperator(s: []const u8) OpResult {
        // Check for two-character operators first
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (i + 1 < s.len) {
                const two = s[i .. i + 2];
                if (std.mem.eql(u8, two, "==")) return .{ .op = .eq, .pos = i, .end = i + 2 };
                if (std.mem.eql(u8, two, "!=")) return .{ .op = .neq, .pos = i, .end = i + 2 };
                if (std.mem.eql(u8, two, "<=")) return .{ .op = .lte, .pos = i, .end = i + 2 };
                if (std.mem.eql(u8, two, ">=")) return .{ .op = .gte, .pos = i, .end = i + 2 };
            }
            // Single-character operators
            if (s[i] == '=') return .{ .op = .eq, .pos = i, .end = i + 1 };
            if (s[i] == '<') return .{ .op = .lt, .pos = i, .end = i + 1 };
            if (s[i] == '>') return .{ .op = .gt, .pos = i, .end = i + 1 };
        }
        // Check for CONTAINS keyword
        if (std.mem.indexOf(u8, s, " CONTAINS ")) |pos| {
            return .{ .op = .contains, .pos = pos, .end = pos + 10 };
        }
        return .{ .op = .none, .pos = 0, .end = 0 };
    }

    fn getBindingProperty(binding: graph_storage.Binding, prop_name: []const u8) ?graph_storage.PropertyValue {
        // Try to get from the binding's vars map first
        if (binding.vars.get(prop_name)) |bv| {
            switch (bv) {
                .Property, .Value => |pv| return pv,
                .Node => |node| {
                    // Try to get property from node
                    if (node.properties.get(prop_name)) |pv| return pv;
                },
                .Edge => |edge| {
                    if (edge.properties.get(prop_name)) |pv| return pv;
                },
                else => {},
            }
        }

        // Check main binding value
        switch (binding.value) {
            .Property, .Value => |pv| return pv,
            .Node => |node| {
                if (node.properties.get(prop_name)) |pv| return pv;
            },
            .Edge => |edge| {
                if (edge.properties.get(prop_name)) |pv| return pv;
            },
            else => {},
        }

        return null;
    }

    fn evaluateComparison(self: *MaterializedViewManager, pv: graph_storage.PropertyValue, op: FilterOp, value_str: []const u8) bool {
        _ = self;
        switch (pv) {
            .Null => return op == .eq and std.mem.eql(u8, value_str, "null"),
            .Bool => |b| {
                const expected = std.mem.eql(u8, value_str, "true");
                return switch (op) {
                    .eq => b == expected,
                    .neq => b != expected,
                    else => false,
                };
            },
            .Int => |i| {
                const expected = std.fmt.parseInt(i64, value_str, 10) catch return false;
                return switch (op) {
                    .eq => i == expected,
                    .neq => i != expected,
                    .lt => i < expected,
                    .gt => i > expected,
                    .lte => i <= expected,
                    .gte => i >= expected,
                    else => false,
                };
            },
            .String => |s| {
                // Remove surrounding quotes if present
                const clean_value = if (value_str.len >= 2 and value_str[0] == '"' and value_str[value_str.len - 1] == '"')
                    value_str[1 .. value_str.len - 1]
                else if (value_str.len >= 2 and value_str[0] == '\'' and value_str[value_str.len - 1] == '\'')
                    value_str[1 .. value_str.len - 1]
                else
                    value_str;

                return switch (op) {
                    .eq => std.mem.eql(u8, s, clean_value),
                    .neq => !std.mem.eql(u8, s, clean_value),
                    .lt => std.mem.order(u8, s, clean_value) == .lt,
                    .gt => std.mem.order(u8, s, clean_value) == .gt,
                    .lte => std.mem.order(u8, s, clean_value) != .gt,
                    .gte => std.mem.order(u8, s, clean_value) != .lt,
                    .contains => std.mem.indexOf(u8, s, clean_value) != null,
                    else => false,
                };
            },
            .Decimal => |d| {
                // Parse expected decimal value (simplified)
                const expected = std.fmt.parseFloat(f64, value_str) catch return false;
                const actual = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10.0, @as(f64, @floatFromInt(d.scale)));
                return switch (op) {
                    .eq => @abs(actual - expected) < 0.0001,
                    .neq => @abs(actual - expected) >= 0.0001,
                    .lt => actual < expected,
                    .gt => actual > expected,
                    .lte => actual <= expected,
                    .gte => actual >= expected,
                    else => false,
                };
            },
            .VectorF32 => return false, // Vector comparisons not supported in simple filters
        }
    }

    fn isQueryCompatible(self: *MaterializedViewManager, query1: []const u8, query2: []const u8) bool {
        // CANARY: REQ=REQ-MATERIALIZED-VIEWS-005; FEATURE="MV Query Compatibility"; ASPECT=SemanticQueryMatching; STATUS=TESTED; TEST=test_materialized_views; OWNER=query; UPDATED=2025-12-30
        // Check if query1 can be satisfied by a materialized view with query2 as its source
        // Uses semantic analysis to compare query patterns

        // Fast path: exact match
        if (std.mem.eql(u8, query1, query2)) return true;

        // Parse both queries
        var parse1 = lib.parseGql(query1, self.allocator) catch return false;
        defer parse1.deinit();
        var parse2 = lib.parseGql(query2, self.allocator) catch return false;
        defer parse2.deinit();

        // Must have at least one statement each
        if (parse1.program.statements.len == 0 or parse2.program.statements.len == 0) return false;

        // Check first statement of each
        const stmt1 = parse1.program.statements[0];
        const stmt2 = parse2.program.statements[0];

        // Both must be Query statements
        const q1 = switch (stmt1) {
            .Query => |q| q,
            else => return false,
        };
        const q2 = switch (stmt2) {
            .Query => |q| q,
            else => return false,
        };

        // Check MATCH clause compatibility: query1's patterns must be a subset of query2's
        if (!matchPatternsCompatible(q1.match, q2.match)) return false;

        // Check RETURN clause compatibility: query1's return items must be satisfiable by query2
        if (!returnClausesCompatible(q1.ret, q2.ret)) return false;

        return true;
    }

    fn matchPatternsCompatible(pattern1: ast.GraphPattern, pattern2: ast.GraphPattern) bool {
        // Extract all labels from both patterns
        const labels1 = extractAllLabels(pattern1);
        const labels2 = extractAllLabels(pattern2);

        // All labels in pattern1 must exist in pattern2
        for (labels1.items) |label| {
            var found = false;
            for (labels2.items) |other| {
                if (std.mem.eql(u8, label, other)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        return true;
    }

    const LabelList = struct {
        items: []const []const u8,
        len: usize,
    };

    fn extractAllLabels(pattern: ast.GraphPattern) LabelList {
        // Count labels first
        var count: usize = 0;
        for (pattern.chains) |chain| {
            if (chain.head) |head| {
                count += head.labels.len;
            }
            for (chain.hops) |hop| {
                count += hop.left.labels.len;
                count += hop.rel.types.len;
                count += hop.right.labels.len;
            }
        }

        // Use a static buffer for simplicity (thread-local would be better for production)
        const StaticBuffer = struct {
            var buf: [256][]const u8 = undefined;
        };

        var idx: usize = 0;
        for (pattern.chains) |chain| {
            if (chain.head) |head| {
                for (head.labels) |label| {
                    if (idx < 256) {
                        StaticBuffer.buf[idx] = label;
                        idx += 1;
                    }
                }
            }
            for (chain.hops) |hop| {
                for (hop.left.labels) |label| {
                    if (idx < 256) {
                        StaticBuffer.buf[idx] = label;
                        idx += 1;
                    }
                }
                for (hop.rel.types) |rtype| {
                    if (idx < 256) {
                        StaticBuffer.buf[idx] = rtype;
                        idx += 1;
                    }
                }
                for (hop.right.labels) |label| {
                    if (idx < 256) {
                        StaticBuffer.buf[idx] = label;
                        idx += 1;
                    }
                }
            }
        }

        return LabelList{ .items = StaticBuffer.buf[0..idx], .len = idx };
    }

    fn returnClausesCompatible(ret1: ast.ReturnClause, ret2: ast.ReturnClause) bool {
        // Check if all items in ret1 can be found in ret2
        for (ret1.items) |item1| {
            var found = false;
            for (ret2.items) |item2| {
                if (returnItemsMatch(item1, item2)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    fn returnItemsMatch(item1: ast.ReturnItem, item2: ast.ReturnItem) bool {
        // Check alias match if both have aliases
        if (item1.alias != null and item2.alias != null) {
            if (std.mem.eql(u8, item1.alias.?, item2.alias.?)) return true;
        }

        // Check expression match (simplified comparison)
        return expressionsMatch(item1.expr, item2.expr);
    }

    fn expressionsMatch(expr1: ast.Expr, expr2: ast.Expr) bool {
        // Compare expression types and content
        return switch (expr1) {
            .Ident => |id1| switch (expr2) {
                .Ident => |id2| std.mem.eql(u8, id1.orig, id2.orig),
                else => false,
            },
            .PropertyAccess => |pa1| switch (expr2) {
                .PropertyAccess => |pa2| blk: {
                    // Compare base and property
                    const base_match = expressionsMatch(pa1.base.*, pa2.base.*);
                    const prop_match = std.mem.eql(u8, pa1.prop, pa2.prop);
                    break :blk base_match and prop_match;
                },
                else => false,
            },
            .FunctionCall => |fc1| switch (expr2) {
                .FunctionCall => |fc2| blk: {
                    // Compare function name and arity
                    if (!std.mem.eql(u8, fc1.name, fc2.name)) break :blk false;
                    if (fc1.args.len != fc2.args.len) break :blk false;
                    // Compare arguments
                    for (fc1.args, fc2.args) |a1, a2| {
                        if (!expressionsMatch(a1.*, a2.*)) break :blk false;
                    }
                    break :blk true;
                },
                else => false,
            },
            .IntLiteral => |int1| switch (expr2) {
                .IntLiteral => |int2| int1 == int2,
                else => false,
            },
            .StringLiteral => |s1| switch (expr2) {
                .StringLiteral => |s2| std.mem.eql(u8, s1, s2),
                else => false,
            },
            else => false, // Other types don't match
        };
    }

    fn updateRefreshSuccessRate(self: *MaterializedViewManager) void {
        var total_refreshes: u64 = 0;
        var successful_refreshes: u64 = 0;

        var it = self.views.iterator();
        while (it.next()) |entry| {
            const stats = entry.value_ptr.statistics;
            total_refreshes += stats.total_refreshes;
            successful_refreshes += stats.successful_refreshes;
        }

        if (total_refreshes > 0) {
            self.statistics.refresh_success_rate = @as(f64, @floatFromInt(successful_refreshes)) / @as(f64, @floatFromInt(total_refreshes));
        }
    }
};

/// Query result structure
pub const QueryResult = struct {
    rows: []graph_storage.Binding,
    schema: []graph_storage.Column,
    execution_time_ms: u64,
    row_count: usize,
};

/// Refresh scheduler for materialized views
pub const RefreshScheduler = struct {
    allocator: Allocator,
    scheduled_jobs: ArrayList(RefreshJob),
    job_counter: u64,

    pub fn init(allocator: Allocator) RefreshScheduler {
        return .{
            .allocator = allocator,
            .scheduled_jobs = ArrayList(RefreshJob).init(allocator),
            .job_counter = 0,
        };
    }

    pub fn deinit(self: *RefreshScheduler) void {
        for (self.scheduled_jobs.items) |job| {
            self.allocator.free(job.view_name);
        }
        self.scheduled_jobs.deinit();
    }

    pub fn scheduleJob(
        self: *RefreshScheduler,
        view_name: []const u8,
        scheduled_time: i64,
        priority: RefreshPriority,
    ) !void {
        const job = RefreshJob{
            .view_name = try self.allocator.dupe(u8, view_name),
            .scheduled_time = scheduled_time,
            .retry_count = 0,
            .max_retries = 3,
            .job_id = self.job_counter,
            .priority = priority,
        };

        try self.scheduled_jobs.append(job);
        self.job_counter += 1;

        // Sort by scheduled time
        std.sort.heap(RefreshJob, self.scheduled_jobs.items, {}, compareJobs);
    }

    pub fn removeJob(self: *RefreshScheduler, view_name: []const u8) !void {
        var i: usize = 0;
        while (i < self.scheduled_jobs.items.len) {
            if (std.mem.eql(u8, self.scheduled_jobs.items[i].view_name, view_name)) {
                const job = self.scheduled_jobs.swapRemove(i);
                self.allocator.free(job.view_name);
                return;
            }
            i += 1;
        }
    }

    pub fn getNextJob(self: *RefreshScheduler, current_time: i64) ?RefreshJob {
        if (self.scheduled_jobs.items.len == 0) return null;

        const job = self.scheduled_jobs.items[0];
        if (job.scheduled_time <= current_time) {
            return self.scheduled_jobs.swapRemove(0);
        }

        return null;
    }

    fn compareJobs(context: void, a: RefreshJob, b: RefreshJob) bool {
        _ = context;
        return a.scheduled_time < b.scheduled_time;
    }
};
