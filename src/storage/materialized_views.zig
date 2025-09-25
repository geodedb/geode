const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast.zig");
const planner = @import("../planner.zig");
const exec = @import("../exec.zig");
const storage = @import("interface.zig");
const wal = @import("../wal/wal.zig");

// Materialized Views with incremental refresh and dependency tracking
pub const MaterializedViewManager = struct {
    allocator: Allocator,
    storage_engine: *storage.StorageEngine,
    view_catalog: ViewCatalog,
    dependency_tracker: DependencyTracker,
    refresh_manager: RefreshManager,
    query_rewriter: QueryRewriter,
    statistics: ViewStatistics,

    const Self = @This();

    pub const ViewCatalog = struct {
        allocator: Allocator,
        views: std.StringHashMap(MaterializedView),
        view_by_id: std.AutoHashMap(u64, *MaterializedView),
        next_view_id: u64,

        pub const MaterializedView = struct {
            id: u64,
            name: []const u8,
            schema: []const u8,
            definition: ViewDefinition,
            storage: ViewStorage,
            refresh: RefreshPolicy,
            dependencies: []Dependency,
            statistics: ViewStats,
            metadata: ViewMetadata,

            pub const ViewDefinition = struct {
                query_text: []const u8,
                parsed_query: *ast.Query,
                compiled_plan: *planner.PhysicalPlan,
                output_columns: []Column,
                parameters: []Parameter,

                pub const Column = struct {
                    name: []const u8,
                    type: ast.ValueType,
                    nullable: bool,
                    expression: ?[]const u8,
                };

                pub const Parameter = struct {
                    name: []const u8,
                    type: ast.ValueType,
                    default_value: ?exec.Value,
                };
            };

            pub const ViewStorage = struct {
                storage_type: StorageType,
                primary_key: []const []const u8,
                indexes: []Index,
                partitioning: ?Partitioning,
                compression: CompressionType,
                estimated_size_bytes: u64,
                actual_size_bytes: u64,

                pub const StorageType = enum {
                    heap,
                    columnar,
                    in_memory,
                    hybrid,
                };

                pub const Index = struct {
                    name: []const u8,
                    columns: []const []const u8,
                    type: enum { btree, hash, gin, gist },
                    unique: bool,
                    where_clause: ?[]const u8,
                };

                pub const Partitioning = struct {
                    strategy: enum { range, list, hash },
                    key: []const []const u8,
                    partitions: []Partition,

                    pub const Partition = struct {
                        name: []const u8,
                        constraint: []const u8,
                        storage_params: ?[]const u8,
                    };
                };

                pub const CompressionType = enum {
                    none,
                    zstd,
                    lz4,
                    snappy,
                };
            };

            pub const RefreshPolicy = struct {
                method: RefreshMethod,
                timing: RefreshTiming,
                incremental: IncrementalConfig,
                concurrency: ConcurrencyControl,

                pub const RefreshMethod = enum {
                    complete, // Full refresh
                    incremental, // Incremental using changes
                    differential, // Using deltas
                    deferred, // Lazy evaluation
                };

                pub const RefreshTiming = union(enum) {
                    on_commit,
                    on_statement,
                    on_demand,
                    scheduled: Schedule,
                    continuous: ContinuousConfig,
                };

                pub const Schedule = struct {
                    interval_seconds: u64,
                    last_refresh: i64,
                    next_refresh: i64,
                };

                pub const ContinuousConfig = struct {
                    lag_threshold_ms: u64,
                    batch_size: u32,
                };

                pub const IncrementalConfig = struct {
                    enabled: bool,
                    change_capture_method: ChangeCaptureMethod,
                    delta_table: ?[]const u8,
                    watermark_column: ?[]const u8,
                    last_watermark: ?exec.Value,

                    pub const ChangeCaptureMethod = enum {
                        trigger_based,
                        log_based,
                        timestamp_based,
                        version_based,
                    };
                };

                pub const ConcurrencyControl = struct {
                    allow_concurrent_refresh: bool,
                    lock_mode: LockMode,
                    max_parallel_workers: u32,

                    pub const LockMode = enum {
                        exclusive,
                        share,
                        share_row_exclusive,
                        none,
                    };
                };
            };

            pub const Dependency = struct {
                type: DependencyType,
                object_id: u64,
                object_name: []const u8,
                columns: []const []const u8,

                pub const DependencyType = enum {
                    table,
                    view,
                    materialized_view,
                    function,
                    index,
                };
            };

            pub const ViewStats = struct {
                row_count: u64,
                last_refresh_time: i64,
                last_refresh_duration_ms: u64,
                refresh_count: u64,
                error_count: u64,
                last_error: ?[]const u8,
                staleness_seconds: u64,
            };

            pub const ViewMetadata = struct {
                created_at: i64,
                created_by: []const u8,
                modified_at: i64,
                modified_by: []const u8,
                description: ?[]const u8,
                tags: []const []const u8,
                options: std.StringHashMap([]const u8),
            };
        };
    };

    pub const DependencyTracker = struct {
        allocator: Allocator,
        dependency_graph: DependencyGraph,
        invalidation_queue: std.ArrayList(InvalidationEvent),
        subscription_manager: SubscriptionManager,

        pub const DependencyGraph = struct {
            nodes: std.AutoHashMap(u64, Node),
            edges: std.ArrayList(Edge),
            topological_order: ?[]u64,

            pub const Node = struct {
                id: u64,
                type: NodeType,
                name: []const u8,
                dependents: std.ArrayList(u64),
                dependencies: std.ArrayList(u64),

                pub const NodeType = enum {
                    table,
                    view,
                    materialized_view,
                    index,
                };
            };

            pub const Edge = struct {
                from: u64,
                to: u64,
                dependency_type: EdgeType,

                pub const EdgeType = enum {
                    data,
                    schema,
                    function,
                };
            };
        };

        pub const InvalidationEvent = struct {
            timestamp: i64,
            source_object: u64,
            event_type: EventType,
            affected_views: []u64,
            propagation_depth: u32,

            pub const EventType = enum {
                insert,
                update,
                delete,
                truncate,
                schema_change,
            };
        };

        pub const SubscriptionManager = struct {
            subscriptions: std.AutoHashMap(u64, []Subscription),

            pub const Subscription = struct {
                view_id: u64,
                table_id: u64,
                columns: []const []const u8,
                filter: ?[]const u8,
                callback: *const fn (event: InvalidationEvent) void,
            };
        };
    };

    pub const RefreshManager = struct {
        allocator: Allocator,
        active_refreshes: std.AutoHashMap(u64, RefreshJob),
        refresh_queue: PriorityQueue,
        scheduler: RefreshScheduler,
        incremental_engine: IncrementalEngine,

        pub const RefreshJob = struct {
            view_id: u64,
            status: JobStatus,
            start_time: i64,
            progress: Progress,
            worker_thread: ?std.Thread,
            cancellation_token: CancellationToken,

            pub const JobStatus = enum {
                pending,
                running,
                completed,
                failed,
                cancelled,
            };

            pub const Progress = struct {
                total_rows: u64,
                processed_rows: u64,
                current_phase: []const u8,
                phases_completed: u32,
                total_phases: u32,
            };

            pub const CancellationToken = struct {
                cancelled: std.atomic.Atomic(bool),

                pub fn cancel(self: *CancellationToken) void {
                    self.cancelled.store(true, .Monotonic);
                }

                pub fn isCancelled(self: *const CancellationToken) bool {
                    return self.cancelled.load(.Monotonic);
                }
            };
        };

        pub const PriorityQueue = struct {
            items: std.ArrayList(QueueItem),

            pub const QueueItem = struct {
                view_id: u64,
                priority: f32,
                scheduled_time: i64,
                retry_count: u32,
            };
        };

        pub const RefreshScheduler = struct {
            schedule_table: std.AutoHashMap(u64, ScheduleEntry),
            timer_wheel: TimerWheel,

            pub const ScheduleEntry = struct {
                view_id: u64,
                cron_expression: ?[]const u8,
                interval_seconds: ?u64,
                next_run: i64,
                dependencies_satisfied: bool,
            };

            pub const TimerWheel = struct {
                slots: []std.ArrayList(u64),
                current_slot: usize,
                tick_duration_ms: u64,
            };
        };

        pub const IncrementalEngine = struct {
            delta_processor: DeltaProcessor,
            merge_engine: MergeEngine,
            conflict_resolver: ConflictResolver,

            pub const DeltaProcessor = struct {
                pending_deltas: std.ArrayList(Delta),
                delta_log: DeltaLog,

                pub const Delta = struct {
                    operation: Operation,
                    old_value: ?[]exec.Value,
                    new_value: ?[]exec.Value,
                    timestamp: i64,
                    transaction_id: u64,

                    pub const Operation = enum {
                        insert,
                        update,
                        delete,
                    };
                };

                pub const DeltaLog = struct {
                    log_entries: std.ArrayList(LogEntry),
                    checkpoint_lsn: u64,

                    pub const LogEntry = struct {
                        lsn: u64,
                        delta: Delta,
                        applied: bool,
                    };
                };
            };

            pub const MergeEngine = struct {
                merge_strategy: MergeStrategy,
                batch_size: u32,

                pub const MergeStrategy = enum {
                    append_only,
                    upsert,
                    merge_on_read,
                    merge_on_write,
                };
            };

            pub const ConflictResolver = struct {
                resolution_policy: ResolutionPolicy,

                pub const ResolutionPolicy = enum {
                    last_write_wins,
                    first_write_wins,
                    custom_function,
                    manual,
                };
            };
        };
    };

    pub const QueryRewriter = struct {
        allocator: Allocator,
        rewrite_rules: []RewriteRule,
        cost_estimator: CostEstimator,

        pub const RewriteRule = struct {
            pattern: Pattern,
            replacement: Replacement,
            conditions: []Condition,

            pub const Pattern = struct {
                query_template: []const u8,
                table_references: []const []const u8,
            };

            pub const Replacement = struct {
                view_name: []const u8,
                column_mapping: std.StringHashMap([]const u8),
            };

            pub const Condition = struct {
                type: ConditionType,
                parameters: []const u8,

                pub const ConditionType = enum {
                    staleness_threshold,
                    cost_threshold,
                    row_count_threshold,
                    custom,
                };
            };
        };

        pub const CostEstimator = struct {
            base_table_costs: std.StringHashMap(f64),
            view_costs: std.StringHashMap(f64),

            pub fn estimateCost(self: *CostEstimator, query: *ast.Query) f64 {
                _ = self;
                _ = query;
                // TODO: Implement cost estimation
                return 0.0;
            }
        };
    };

    pub const ViewStatistics = struct {
        total_views: u64,
        active_views: u64,
        total_refreshes: u64,
        failed_refreshes: u64,
        average_refresh_time_ms: f64,
        cache_hit_ratio: f32,
        storage_used_bytes: u64,
    };

    pub fn init(allocator: Allocator, storage_engine: *storage.StorageEngine) !MaterializedViewManager {
        return MaterializedViewManager{
            .allocator = allocator,
            .storage_engine = storage_engine,
            .view_catalog = try initViewCatalog(allocator),
            .dependency_tracker = try initDependencyTracker(allocator),
            .refresh_manager = try initRefreshManager(allocator),
            .query_rewriter = try initQueryRewriter(allocator),
            .statistics = ViewStatistics{
                .total_views = 0,
                .active_views = 0,
                .total_refreshes = 0,
                .failed_refreshes = 0,
                .average_refresh_time_ms = 0.0,
                .cache_hit_ratio = 0.0,
                .storage_used_bytes = 0,
            },
        };
    }

    pub fn deinit(self: *MaterializedViewManager) void {
        self.view_catalog.views.deinit();
        self.view_catalog.view_by_id.deinit();
        self.dependency_tracker.dependency_graph.nodes.deinit();
        self.dependency_tracker.invalidation_queue.deinit();
        self.refresh_manager.active_refreshes.deinit();
        self.refresh_manager.refresh_queue.items.deinit();
    }

    pub fn createMaterializedView(
        self: *MaterializedViewManager,
        name: []const u8,
        query: []const u8,
        options: CreateOptions,
    ) !void {
        // Parse and validate query
        const parsed = try ast.parse(self.allocator, query);
        defer parsed.deinit();

        // Generate execution plan
        const plan = try planner.compile(self.allocator, parsed);

        // Create view definition
        const view = ViewCatalog.MaterializedView{
            .id = self.view_catalog.next_view_id,
            .name = try self.allocator.dupe(u8, name),
            .schema = options.schema orelse "public",
            .definition = .{
                .query_text = try self.allocator.dupe(u8, query),
                .parsed_query = parsed,
                .compiled_plan = plan,
                .output_columns = try self.extractColumns(parsed),
                .parameters = &[_]ViewCatalog.MaterializedView.ViewDefinition.Parameter{},
            },
            .storage = .{
                .storage_type = options.storage_type orelse .heap,
                .primary_key = options.primary_key orelse &[_][]const u8{},
                .indexes = try self.createDefaultIndexes(parsed),
                .partitioning = options.partitioning,
                .compression = options.compression orelse .none,
                .estimated_size_bytes = 0,
                .actual_size_bytes = 0,
            },
            .refresh = .{
                .method = options.refresh_method orelse .complete,
                .timing = options.refresh_timing orelse .on_demand,
                .incremental = .{
                    .enabled = options.enable_incremental orelse false,
                    .change_capture_method = .log_based,
                    .delta_table = null,
                    .watermark_column = null,
                    .last_watermark = null,
                },
                .concurrency = .{
                    .allow_concurrent_refresh = options.allow_concurrent orelse false,
                    .lock_mode = .share,
                    .max_parallel_workers = options.max_parallel_workers orelse 4,
                },
            },
            .dependencies = try self.extractDependencies(parsed),
            .statistics = .{
                .row_count = 0,
                .last_refresh_time = 0,
                .last_refresh_duration_ms = 0,
                .refresh_count = 0,
                .error_count = 0,
                .last_error = null,
                .staleness_seconds = 0,
            },
            .metadata = .{
                .created_at = std.time.milliTimestamp(),
                .created_by = options.created_by orelse "system",
                .modified_at = std.time.milliTimestamp(),
                .modified_by = options.created_by orelse "system",
                .description = options.description,
                .tags = options.tags orelse &[_][]const u8{},
                .options = std.StringHashMap([]const u8).init(self.allocator),
            },
        };

        // Register view in catalog
        try self.view_catalog.views.put(name, view);
        try self.view_catalog.view_by_id.put(view.id, &view);
        self.view_catalog.next_view_id += 1;

        // Update dependency graph
        try self.updateDependencyGraph(&view);

        // Perform initial population if requested
        if (options.populate_initially orelse true) {
            try self.refreshView(view.id, .{});
        }

        // Schedule if needed
        if (view.refresh.timing == .scheduled) {
            try self.scheduleRefresh(&view);
        }

        self.statistics.total_views += 1;
        self.statistics.active_views += 1;
    }

    pub fn refreshView(self: *MaterializedViewManager, view_id: u64, options: RefreshOptions) !void {
        const view = self.view_catalog.view_by_id.get(view_id) orelse return error.ViewNotFound;

        // Check if refresh is already in progress
        if (self.refresh_manager.active_refreshes.contains(view_id)) {
            if (!options.wait_for_completion) {
                return error.RefreshInProgress;
            }
            try self.waitForRefresh(view_id);
            return;
        }

        // Create refresh job
        const job = RefreshManager.RefreshJob{
            .view_id = view_id,
            .status = .pending,
            .start_time = std.time.milliTimestamp(),
            .progress = .{
                .total_rows = 0,
                .processed_rows = 0,
                .current_phase = "initializing",
                .phases_completed = 0,
                .total_phases = 3,
            },
            .worker_thread = null,
            .cancellation_token = .{
                .cancelled = std.atomic.Atomic(bool).init(false),
            },
        };

        try self.refresh_manager.active_refreshes.put(view_id, job);

        // Determine refresh method
        const refresh_method = if (options.force_complete orelse false)
            ViewCatalog.MaterializedView.RefreshPolicy.RefreshMethod.complete
        else
            view.refresh.method;

        switch (refresh_method) {
            .complete => try self.performCompleteRefresh(view, &job),
            .incremental => try self.performIncrementalRefresh(view, &job),
            .differential => try self.performDifferentialRefresh(view, &job),
            .deferred => {}, // No-op for deferred
        }

        // Update statistics
        const end_time = std.time.milliTimestamp();
        view.statistics.last_refresh_time = end_time;
        view.statistics.last_refresh_duration_ms = @intCast(u64, end_time - job.start_time);
        view.statistics.refresh_count += 1;
        self.statistics.total_refreshes += 1;

        // Remove from active refreshes
        _ = self.refresh_manager.active_refreshes.remove(view_id);
    }

    pub fn rewriteQuery(self: *MaterializedViewManager, query: *ast.Query) !*ast.Query {
        // Check if query can use materialized views
        const applicable_views = try self.findApplicableViews(query);
        defer self.allocator.free(applicable_views);

        if (applicable_views.len == 0) {
            return query;
        }

        // Estimate costs for each option
        var best_cost = try self.query_rewriter.cost_estimator.estimateCost(query);
        var best_rewrite: ?*ast.Query = null;

        for (applicable_views) |view| {
            const rewritten = try self.rewriteWithView(query, view);
            const cost = try self.query_rewriter.cost_estimator.estimateCost(rewritten);

            if (cost < best_cost) {
                best_cost = cost;
                if (best_rewrite) |old| self.allocator.destroy(old);
                best_rewrite = rewritten;
            } else {
                self.allocator.destroy(rewritten);
            }
        }

        return best_rewrite orelse query;
    }

    // Helper functions
    fn initViewCatalog(allocator: Allocator) !ViewCatalog {
        return ViewCatalog{
            .allocator = allocator,
            .views = std.StringHashMap(ViewCatalog.MaterializedView).init(allocator),
            .view_by_id = std.AutoHashMap(u64, *ViewCatalog.MaterializedView).init(allocator),
            .next_view_id = 1,
        };
    }

    fn initDependencyTracker(allocator: Allocator) !DependencyTracker {
        return DependencyTracker{
            .allocator = allocator,
            .dependency_graph = .{
                .nodes = std.AutoHashMap(u64, DependencyTracker.DependencyGraph.Node).init(allocator),
                .edges = std.ArrayList(DependencyTracker.DependencyGraph.Edge).init(allocator),
                .topological_order = null,
            },
            .invalidation_queue = std.ArrayList(DependencyTracker.InvalidationEvent).init(allocator),
            .subscription_manager = .{
                .subscriptions = std.AutoHashMap(u64, []DependencyTracker.SubscriptionManager.Subscription).init(allocator),
            },
        };
    }

    fn initRefreshManager(allocator: Allocator) !RefreshManager {
        return RefreshManager{
            .allocator = allocator,
            .active_refreshes = std.AutoHashMap(u64, RefreshManager.RefreshJob).init(allocator),
            .refresh_queue = .{
                .items = std.ArrayList(RefreshManager.PriorityQueue.QueueItem).init(allocator),
            },
            .scheduler = .{
                .schedule_table = std.AutoHashMap(u64, RefreshManager.RefreshScheduler.ScheduleEntry).init(allocator),
                .timer_wheel = .{
                    .slots = try allocator.alloc(std.ArrayList(u64), 3600),
                    .current_slot = 0,
                    .tick_duration_ms = 1000,
                },
            },
            .incremental_engine = .{
                .delta_processor = .{
                    .pending_deltas = std.ArrayList(RefreshManager.IncrementalEngine.DeltaProcessor.Delta).init(allocator),
                    .delta_log = .{
                        .log_entries = std.ArrayList(RefreshManager.IncrementalEngine.DeltaProcessor.DeltaLog.LogEntry).init(allocator),
                        .checkpoint_lsn = 0,
                    },
                },
                .merge_engine = .{
                    .merge_strategy = .merge_on_write,
                    .batch_size = 1000,
                },
                .conflict_resolver = .{
                    .resolution_policy = .last_write_wins,
                },
            },
        };
    }

    fn initQueryRewriter(allocator: Allocator) !QueryRewriter {
        return QueryRewriter{
            .allocator = allocator,
            .rewrite_rules = try allocator.alloc(QueryRewriter.RewriteRule, 0),
            .cost_estimator = .{
                .base_table_costs = std.StringHashMap(f64).init(allocator),
                .view_costs = std.StringHashMap(f64).init(allocator),
            },
        };
    }

    fn extractColumns(self: *MaterializedViewManager, query: *ast.Query) ![]ViewCatalog.MaterializedView.ViewDefinition.Column {
        _ = self;
        _ = query;
        // TODO: Extract columns from query
        return &[_]ViewCatalog.MaterializedView.ViewDefinition.Column{};
    }

    fn createDefaultIndexes(self: *MaterializedViewManager, query: *ast.Query) ![]ViewCatalog.MaterializedView.ViewStorage.Index {
        _ = self;
        _ = query;
        // TODO: Create default indexes
        return &[_]ViewCatalog.MaterializedView.ViewStorage.Index{};
    }

    fn extractDependencies(self: *MaterializedViewManager, query: *ast.Query) ![]ViewCatalog.MaterializedView.Dependency {
        _ = self;
        _ = query;
        // TODO: Extract dependencies
        return &[_]ViewCatalog.MaterializedView.Dependency{};
    }

    fn updateDependencyGraph(self: *MaterializedViewManager, view: *ViewCatalog.MaterializedView) !void {
        _ = self;
        _ = view;
        // TODO: Update dependency graph
    }

    fn scheduleRefresh(self: *MaterializedViewManager, view: *ViewCatalog.MaterializedView) !void {
        _ = self;
        _ = view;
        // TODO: Schedule refresh
    }

    fn waitForRefresh(self: *MaterializedViewManager, view_id: u64) !void {
        _ = self;
        _ = view_id;
        // TODO: Wait for refresh completion
    }

    pub fn performCompleteRefresh(self: *MaterializedViewManager, view_id: u64) !void {
        // Acquire single-flight lock
        self.refresh_manager.refresh_mutex.lock();
        defer self.refresh_manager.refresh_mutex.unlock();
        
        const view = self.catalog.views.get(view_id) orelse return error.ViewNotFound;
        
        // Check if refresh already in progress
        if (self.refresh_manager.active_refreshes.get(view_id) != null) {
            return error.RefreshInProgress;
        }
        
        // Mark as active
        const job = try self.allocator.create(RefreshManager.RefreshJob);
        job.* = .{
            .view_id = view_id,
            .method = .complete,
            .status = .running,
            .start_time = std.time.milliTimestamp(),
            .end_time = null,
            .error_message = null,
            .rows_processed = 0,
            .memory_used_bytes = 0,
            .worker_count = 1,
        };
        try self.refresh_manager.active_refreshes.put(view_id, job);
        defer {
            _ = self.refresh_manager.active_refreshes.remove(view_id);
            self.allocator.destroy(job);
        }
        
        // Begin transaction for snapshot read
        const txn = try self.storage_engine.beginTransaction(.read_committed);
        defer txn.rollback() catch {};
        
        // Execute the view's defining query
        const query_result = try self.query_executor.execute(view.definition_query, txn);
        defer query_result.deinit();
        
        // Create new storage for refreshed data
        const temp_storage = try self.storage_engine.createTempTable(view.name);
        defer self.storage_engine.dropTempTable(temp_storage) catch {};
        
        // Insert all rows into temp storage
        var row_count: u64 = 0;
        while (try query_result.next()) |row| {
            try temp_storage.insert(row);
            row_count += 1;
        }
        
        // Atomically swap storage
        const swap_txn = try self.storage_engine.beginTransaction(.serializable);
        errdefer swap_txn.rollback() catch {};
        
        try self.storage_engine.swapTable(view.storage_location, temp_storage, swap_txn);
        try swap_txn.commit();
        
        // Update metrics
        job.rows_processed = row_count;
        job.end_time = std.time.milliTimestamp();
        job.status = .completed;
        
        // Update view metadata
        view.last_refresh_time = std.time.milliTimestamp();
        view.row_count = row_count;
        
        self.refresh_manager.metrics.total_refreshes += 1;
        self.refresh_manager.metrics.complete_refreshes += 1;
    }

    pub fn performIncrementalRefresh(self: *MaterializedViewManager, view_id: u64, since_lsn: u64) !void {
        self.refresh_manager.refresh_mutex.lock();
        defer self.refresh_manager.refresh_mutex.unlock();
        
        const view = self.catalog.views.get(view_id) orelse return error.ViewNotFound;
        
        if (self.refresh_manager.active_refreshes.get(view_id) != null) {
            return error.RefreshInProgress;
        }
        
        const job = try self.allocator.create(RefreshManager.RefreshJob);
        job.* = .{
            .view_id = view_id,
            .method = .incremental,
            .status = .running,
            .start_time = std.time.milliTimestamp(),
            .end_time = null,
            .error_message = null,
            .rows_processed = 0,
            .memory_used_bytes = 0,
            .worker_count = 1,
        };
        try self.refresh_manager.active_refreshes.put(view_id, job);
        defer {
            _ = self.refresh_manager.active_refreshes.remove(view_id);
            self.allocator.destroy(job);
        }
        
        // Get change data since last LSN
        const changes = try self.cdc_engine.getChangesSince(since_lsn);
        defer changes.deinit();
        
        // Apply changes to view storage
        const txn = try self.storage_engine.beginTransaction(.read_committed);
        defer txn.rollback() catch {};
        
        var rows_updated: u64 = 0;
        while (try changes.next()) |change| {
            switch (change.operation) {
                .insert => try view.storage.insert(change.new_data),
                .update => try view.storage.update(change.key, change.new_data),
                .delete => try view.storage.delete(change.key),
            }
            rows_updated += 1;
        }
        
        try txn.commit();
        
        // Update metrics and metadata
        job.rows_processed = rows_updated;
        job.end_time = std.time.milliTimestamp();
        job.status = .completed;
        
        view.last_refresh_time = std.time.milliTimestamp();
        view.last_incremental_lsn = since_lsn;
        
        self.refresh_manager.metrics.total_refreshes += 1;
        self.refresh_manager.metrics.incremental_refreshes += 1;
    }

    fn performDifferentialRefresh(self: *MaterializedViewManager, view: *ViewCatalog.MaterializedView, job: *RefreshManager.RefreshJob) !void {
        _ = self;
        _ = view;
        _ = job;
        // TODO: Perform differential refresh
    }

    fn findApplicableViews(self: *MaterializedViewManager, query: *ast.Query) ![]ViewCatalog.MaterializedView {
        _ = self;
        _ = query;
        // TODO: Find applicable views
        return &[_]ViewCatalog.MaterializedView{};
    }

    fn rewriteWithView(self: *MaterializedViewManager, query: *ast.Query, view: ViewCatalog.MaterializedView) !*ast.Query {
        _ = self;
        _ = view;
        // TODO: Rewrite query to use view
        return query;
    }

    pub const CreateOptions = struct {
        schema: ?[]const u8 = null,
        storage_type: ?ViewCatalog.MaterializedView.ViewStorage.StorageType = null,
        primary_key: ?[]const []const u8 = null,
        partitioning: ?ViewCatalog.MaterializedView.ViewStorage.Partitioning = null,
        compression: ?ViewCatalog.MaterializedView.ViewStorage.CompressionType = null,
        refresh_method: ?ViewCatalog.MaterializedView.RefreshPolicy.RefreshMethod = null,
        refresh_timing: ?ViewCatalog.MaterializedView.RefreshPolicy.RefreshTiming = null,
        enable_incremental: ?bool = null,
        allow_concurrent: ?bool = null,
        max_parallel_workers: ?u32 = null,
        populate_initially: ?bool = null,
        created_by: ?[]const u8 = null,
        description: ?[]const u8 = null,
        tags: ?[]const []const u8 = null,
    };

    pub const RefreshOptions = struct {
        force_complete: ?bool = null,
        wait_for_completion: bool = true,
        parallel_degree: ?u32 = null,
        memory_limit_mb: ?u32 = null,
    };
};
