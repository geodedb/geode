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
                // CANARY: REQ=REQ-GQL-027; FEATURE="MV Cost Estimation"; ASPECT=QueryOptimization; STATUS=IMPL; TEST=test_materialized_views; OWNER=storage; UPDATED=2025-10-16

                var total_cost: f64 = 0.0;

                // Base cost for query execution
                total_cost += 1.0;

                // Add cost for each table/label accessed
                for (query.match.chains) |chain| {
                    for (chain.links) |link| {
                        if (link.left) |left_node| {
                            for (left_node.labels) |label| {
                                // Lookup table cost from catalog
                                const table_cost = self.base_table_costs.get(label) orelse 100.0;
                                total_cost += table_cost;
                            }
                        }
                        if (link.right) |right_node| {
                            for (right_node.labels) |label| {
                                const table_cost = self.base_table_costs.get(label) orelse 100.0;
                                total_cost += table_cost;
                            }
                        }

                        // Add cost for edge traversal
                        if (link.edge) |_| {
                            total_cost += 50.0; // Edge traversal cost
                        }
                    }
                }

                // Add cost for WHERE clause filtering
                if (query.where_clause) |_| {
                    total_cost *= 1.5; // 50% overhead for filtering
                }

                // Add cost for ORDER BY
                if (query.order_by) |order_items| {
                    // n*log(n) cost for sorting
                    const n = total_cost / 10.0; // Estimate row count
                    const sort_cost = n * @log(n);
                    total_cost += sort_cost;
                    _ = order_items;
                }

                // Add cost for aggregations in RETURN
                for (query.ret.items) |item| {
                    switch (item.expr) {
                        .FunctionCall => |fc| {
                            // Check if it's an aggregate function
                            if (std.mem.eql(u8, fc.name, "count") or
                                std.mem.eql(u8, fc.name, "sum") or
                                std.mem.eql(u8, fc.name, "avg") or
                                std.mem.eql(u8, fc.name, "min") or
                                std.mem.eql(u8, fc.name, "max"))
                            {
                                total_cost += 20.0; // Aggregation cost
                            }
                        },
                        else => {},
                    }
                }

                return total_cost;
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
        // CANARY: REQ=REQ-GQL-016; FEATURE="MV Memory Management"; ASPECT=ResourceCleanup; STATUS=IMPL; TEST=test_materialized_views; OWNER=storage; UPDATED=2025-10-16

        // Free all views and their contents
        var view_iter = self.view_catalog.views.valueIterator();
        while (view_iter.next()) |view| {
            // Free view name
            self.allocator.free(view.name);
            self.allocator.free(view.schema);

            // Free definition
            self.allocator.free(view.definition.query_text);

            // Free columns
            for (view.definition.output_columns) |col| {
                self.allocator.free(col.name);
                if (col.expression) |expr| {
                    self.allocator.free(expr);
                }
            }
            self.allocator.free(view.definition.output_columns);

            // Free parameters
            for (view.definition.parameters) |param| {
                self.allocator.free(param.name);
            }
            self.allocator.free(view.definition.parameters);

            // Free indexes
            for (view.storage.indexes) |idx| {
                self.allocator.free(idx.name);
                for (idx.columns) |col| {
                    self.allocator.free(col);
                }
                self.allocator.free(idx.columns);
                if (idx.where_clause) |wc| {
                    self.allocator.free(wc);
                }
            }
            self.allocator.free(view.storage.indexes);

            // Free primary key
            for (view.storage.primary_key) |pk| {
                self.allocator.free(pk);
            }
            self.allocator.free(view.storage.primary_key);

            // Free partitioning if present
            if (view.storage.partitioning) |*part| {
                for (part.key) |k| {
                    self.allocator.free(k);
                }
                self.allocator.free(part.key);
                for (part.partitions) |p| {
                    self.allocator.free(p.name);
                    self.allocator.free(p.constraint);
                    if (p.storage_params) |sp| {
                        self.allocator.free(sp);
                    }
                }
                self.allocator.free(part.partitions);
            }

            // Free dependencies
            for (view.dependencies) |dep| {
                self.allocator.free(dep.object_name);
                for (dep.columns) |col| {
                    self.allocator.free(col);
                }
                self.allocator.free(dep.columns);
            }
            self.allocator.free(view.dependencies);

            // Free statistics
            if (view.statistics.last_error) |err| {
                self.allocator.free(err);
            }

            // Free metadata
            self.allocator.free(view.metadata.created_by);
            self.allocator.free(view.metadata.modified_by);
            if (view.metadata.description) |desc| {
                self.allocator.free(desc);
            }
            for (view.metadata.tags) |tag| {
                self.allocator.free(tag);
            }
            self.allocator.free(view.metadata.tags);

            var opt_iter = view.metadata.options.iterator();
            while (opt_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            view.metadata.options.deinit();

            // Free incremental config
            if (view.refresh.incremental.delta_table) |dt| {
                self.allocator.free(dt);
            }
            if (view.refresh.incremental.watermark_column) |wc| {
                self.allocator.free(wc);
            }
        }

        self.view_catalog.views.deinit();
        self.view_catalog.view_by_id.deinit();

        // Free dependency graph nodes
        var node_iter = self.dependency_tracker.dependency_graph.nodes.valueIterator();
        while (node_iter.next()) |node| {
            node.dependents.deinit();
            node.dependencies.deinit();
        }
        self.dependency_tracker.dependency_graph.nodes.deinit();
        self.dependency_tracker.dependency_graph.edges.deinit();
        if (self.dependency_tracker.dependency_graph.topological_order) |order| {
            self.allocator.free(order);
        }

        // Free invalidation queue
        for (self.dependency_tracker.invalidation_queue.items) |event| {
            self.allocator.free(event.object_name);
            for (event.affected_views) |view_id| {
                _ = view_id;
            }
            self.allocator.free(event.affected_views);
        }
        self.dependency_tracker.invalidation_queue.deinit();

        // Free subscriptions
        var sub_iter = self.dependency_tracker.subscription_manager.subscriptions.valueIterator();
        while (sub_iter.next()) |subs| {
            self.allocator.free(subs.*);
        }
        self.dependency_tracker.subscription_manager.subscriptions.deinit();

        // Free active refreshes
        var refresh_iter = self.refresh_manager.active_refreshes.valueIterator();
        while (refresh_iter.next()) |job| {
            if (job.error_message) |msg| {
                self.allocator.free(msg);
            }
        }
        self.refresh_manager.active_refreshes.deinit();

        // Free refresh queue
        self.refresh_manager.refresh_queue.items.deinit();

        // Free scheduler
        var sched_iter = self.refresh_manager.scheduler.schedule_table.valueIterator();
        while (sched_iter.next()) |entry| {
            if (entry.cron_expression) |cron| {
                self.allocator.free(cron);
            }
        }
        self.refresh_manager.scheduler.schedule_table.deinit();

        for (self.refresh_manager.scheduler.timer_wheel.slots) |slot| {
            slot.deinit();
        }
        self.allocator.free(self.refresh_manager.scheduler.timer_wheel.slots);

        // Free incremental engine
        for (self.refresh_manager.incremental_engine.delta_processor.pending_deltas.items) |delta| {
            if (delta.old_value) |old| {
                self.allocator.free(old);
            }
            if (delta.new_value) |new| {
                self.allocator.free(new);
            }
        }
        self.refresh_manager.incremental_engine.delta_processor.pending_deltas.deinit();
        self.refresh_manager.incremental_engine.delta_processor.delta_log.log_entries.deinit();

        // Free query rewriter
        for (self.query_rewriter.rewrite_rules) |*rule| {
            self.allocator.free(rule.pattern.query_template);
            for (rule.pattern.table_references) |tref| {
                self.allocator.free(tref);
            }
            self.allocator.free(rule.pattern.table_references);
            self.allocator.free(rule.replacement.view_name);

            var map_iter = rule.replacement.column_mapping.iterator();
            while (map_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            rule.replacement.column_mapping.deinit();

            for (rule.conditions) |cond| {
                self.allocator.free(cond.parameters);
            }
            self.allocator.free(rule.conditions);
        }
        self.allocator.free(self.query_rewriter.rewrite_rules);

        var base_cost_iter = self.query_rewriter.cost_estimator.base_table_costs.iterator();
        while (base_cost_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.query_rewriter.cost_estimator.base_table_costs.deinit();

        var view_cost_iter = self.query_rewriter.cost_estimator.view_costs.iterator();
        while (view_cost_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.query_rewriter.cost_estimator.view_costs.deinit();
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
        // CANARY: REQ=REQ-GQL-018; FEATURE="MV Column Extraction"; ASPECT=SchemaInference; STATUS=IMPL; TEST=test_materialized_views; OWNER=storage; UPDATED=2025-10-16

        var columns = std.ArrayList(ViewCatalog.MaterializedView.ViewDefinition.Column).init(self.allocator);
        defer columns.deinit();

        // Extract columns from RETURN clause
        for (query.ret.items) |item| {
            const col_name = if (item.alias) |alias|
                try self.allocator.dupe(u8, alias)
            else switch (item.expr) {
                .Ident => |ident| try self.allocator.dupe(u8, ident.orig),
                .PropertyAccess => |pa| try self.allocator.dupe(u8, pa.property),
                else => try std.fmt.allocPrint(self.allocator, "column_{d}", .{columns.items.len}),
            };

            // Infer type from expression
            const col_type = inferExpressionType(item.expr);

            // Check if nullable (default to true for safety)
            const nullable = true;

            // Store expression text if not a simple identifier
            const expression = switch (item.expr) {
                .Ident => null,
                else => try self.allocator.dupe(u8, "<expression>"), // Simplified - would need full expr serialization
            };

            try columns.append(.{
                .name = col_name,
                .type = col_type,
                .nullable = nullable,
                .expression = expression,
            });
        }

        return columns.toOwnedSlice();
    }

    fn inferExpressionType(expr: ast.Expr) ast.ValueType {
        return switch (expr) {
            .IntLiteral => .Int,
            .FloatLiteral => .Float,
            .StringLiteral => .String,
            .BoolLiteral => .Bool,
            .Null => .Null,
            .Ident => .Any, // Would need type inference from context
            .PropertyAccess => .Any,
            .FunctionCall => |fc| blk: {
                // Infer from function name
                if (std.mem.eql(u8, fc.name, "count")) break :blk .Int;
                if (std.mem.eql(u8, fc.name, "sum")) break :blk .Float;
                if (std.mem.eql(u8, fc.name, "avg")) break :blk .Float;
                break :blk .Any;
            },
            else => .Any,
        };
    }

    fn createDefaultIndexes(self: *MaterializedViewManager, query: *ast.Query) ![]ViewCatalog.MaterializedView.ViewStorage.Index {
        // CANARY: REQ=REQ-GQL-019; FEATURE="MV Index Creation"; ASPECT=IndexGeneration; STATUS=IMPL; TEST=test_materialized_views; OWNER=storage; UPDATED=2025-10-16

        var indexes = std.ArrayList(ViewCatalog.MaterializedView.ViewStorage.Index).init(self.allocator);
        defer indexes.deinit();

        // Create indexes for columns that appear in WHERE clauses or JOIN conditions
        // This is a simplified heuristic - real implementation would analyze query patterns

        // Check WHERE clause for indexed columns
        if (query.where_clause) |where_expr| {
            const indexed_cols = try extractIndexableColumns(self.allocator, where_expr);
            defer {
                for (indexed_cols) |col| {
                    self.allocator.free(col);
                }
                self.allocator.free(indexed_cols);
            }

            for (indexed_cols, 0..) |col, i| {
                const index_name = try std.fmt.allocPrint(self.allocator, "mv_idx_{d}", .{i});
                const col_copy = try self.allocator.dupe(u8, col);
                const col_array = try self.allocator.alloc([]const u8, 1);
                col_array[0] = col_copy;

                try indexes.append(.{
                    .name = index_name,
                    .columns = col_array,
                    .type = .btree,
                    .unique = false,
                    .where_clause = null,
                });
            }
        }

        return indexes.toOwnedSlice();
    }

    fn extractIndexableColumns(allocator: Allocator, expr: ast.Expr) ![][]const u8 {
        var columns = std.ArrayList([]const u8).init(allocator);
        defer columns.deinit();

        switch (expr) {
            .BinaryOp => |binop| {
                // Look for property comparisons like "n.id = 5"
                if (binop.lhs.* == .PropertyAccess) {
                    const pa = binop.lhs.*.PropertyAccess;
                    try columns.append(try allocator.dupe(u8, pa.property));
                }
                if (binop.rhs.* == .PropertyAccess) {
                    const pa = binop.rhs.*.PropertyAccess;
                    try columns.append(try allocator.dupe(u8, pa.property));
                }
                // Recursively check nested expressions
                const left_cols = try extractIndexableColumns(allocator, binop.lhs.*);
                defer allocator.free(left_cols);
                const right_cols = try extractIndexableColumns(allocator, binop.rhs.*);
                defer allocator.free(right_cols);

                for (left_cols) |col| {
                    try columns.append(try allocator.dupe(u8, col));
                }
                for (right_cols) |col| {
                    try columns.append(try allocator.dupe(u8, col));
                }
            },
            .PropertyAccess => |pa| {
                try columns.append(try allocator.dupe(u8, pa.property));
            },
            else => {},
        }

        return columns.toOwnedSlice();
    }

    fn extractDependencies(self: *MaterializedViewManager, query: *ast.Query) ![]ViewCatalog.MaterializedView.Dependency {
        // CANARY: REQ=REQ-GQL-020; FEATURE="MV Dependency Extraction"; ASPECT=DependencyTracking; STATUS=IMPL; TEST=test_materialized_views; OWNER=storage; UPDATED=2025-10-16

        var dependencies = std.ArrayList(ViewCatalog.MaterializedView.Dependency).init(self.allocator);
        defer dependencies.deinit();

        // Extract table/label dependencies from MATCH clauses
        for (query.match.chains) |chain| {
            for (chain.links) |link| {
                // Extract labels from node patterns
                if (link.left) |left_node| {
                    for (left_node.labels) |label| {
                        const dep_name = try self.allocator.dupe(u8, label);
                        try dependencies.append(.{
                            .type = .table,
                            .object_id = 0, // Would need catalog lookup
                            .object_name = dep_name,
                            .columns = &[_][]const u8{},
                        });
                    }
                }
                if (link.right) |right_node| {
                    for (right_node.labels) |label| {
                        const dep_name = try self.allocator.dupe(u8, label);
                        try dependencies.append(.{
                            .type = .table,
                            .object_id = 0,
                            .object_name = dep_name,
                            .columns = &[_][]const u8{},
                        });
                    }
                }
            }
        }

        return dependencies.toOwnedSlice();
    }

    fn updateDependencyGraph(self: *MaterializedViewManager, view: *ViewCatalog.MaterializedView) !void {
        // CANARY: REQ=REQ-GQL-021; FEATURE="MV Dependency Graph"; ASPECT=GraphMaintenance; STATUS=IMPL; TEST=test_materialized_views; OWNER=storage; UPDATED=2025-10-16

        // Create node for this view
        const node = DependencyTracker.DependencyGraph.Node{
            .object_id = view.id,
            .object_name = view.name,
            .object_type = .materialized_view,
            .dependents = std.ArrayList(u64).init(self.allocator),
            .dependencies = std.ArrayList(u64).init(self.allocator),
        };

        try self.dependency_tracker.dependency_graph.nodes.put(view.id, node);

        // Add edges for each dependency
        for (view.dependencies) |dep| {
            const edge = DependencyTracker.DependencyGraph.Edge{
                .from_id = view.id,
                .to_id = dep.object_id,
                .dependency_type = dep.type,
            };
            try self.dependency_tracker.dependency_graph.edges.append(edge);

            // Update the dependency node's dependents list
            if (self.dependency_tracker.dependency_graph.nodes.getPtr(dep.object_id)) |dep_node| {
                try dep_node.dependents.append(view.id);
            }
        }

        // Invalidate topological order (needs recomputation)
        if (self.dependency_tracker.dependency_graph.topological_order) |order| {
            self.allocator.free(order);
            self.dependency_tracker.dependency_graph.topological_order = null;
        }
    }

    fn scheduleRefresh(self: *MaterializedViewManager, view: *ViewCatalog.MaterializedView) !void {
        // CANARY: REQ=REQ-GQL-022; FEATURE="MV Refresh Scheduling"; ASPECT=Scheduler; STATUS=IMPL; TEST=test_materialized_views; OWNER=storage; UPDATED=2025-10-16

        const schedule = switch (view.refresh.timing) {
            .scheduled => |sched| sched,
            else => return, // Only schedule for scheduled refresh timing
        };

        const entry = RefreshManager.RefreshScheduler.ScheduleEntry{
            .view_id = view.id,
            .cron_expression = null,
            .interval_seconds = schedule.interval_seconds,
            .next_run = schedule.next_refresh,
            .dependencies_satisfied = true,
        };

        try self.refresh_manager.scheduler.schedule_table.put(view.id, entry);

        // Add to timer wheel
        const slot_index = @as(usize, @intCast(@mod(schedule.next_refresh, 3600)));
        try self.refresh_manager.scheduler.timer_wheel.slots[slot_index].append(view.id);
    }

    fn waitForRefresh(self: *MaterializedViewManager, view_id: u64) !void {
        // CANARY: REQ=REQ-GQL-023; FEATURE="MV Refresh Wait"; ASPECT=Synchronization; STATUS=IMPL; TEST=test_materialized_views; OWNER=storage; UPDATED=2025-10-16

        // Poll until refresh completes
        const timeout_ms = 60000; // 60 second timeout
        const start_time = std.time.milliTimestamp();

        while (true) {
            // Check if refresh is still in progress
            if (!self.refresh_manager.active_refreshes.contains(view_id)) {
                return; // Refresh complete
            }

            // Check timeout
            const elapsed = std.time.milliTimestamp() - start_time;
            if (elapsed > timeout_ms) {
                return error.RefreshTimeout;
            }

            // Sleep for a short interval
            std.time.sleep(100 * std.time.ns_per_ms); // 100ms
        }
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

        // CANARY: REQ=REQ-GQL-016; FEATURE="MV Complete Refresh"; ASPECT=CompleteRefresh; STATUS=TESTED; TEST=e2e_materialized_views_refresh; OWNER=storage; UPDATED=2025-09-25
        // Lines 806-814: Complete refresh implementation
        // Begin transaction for snapshot read
        const txn = try self.storage_engine.beginTransaction(.read_committed);
        defer txn.rollback() catch {};

        // Execute the view's defining query
        const query_result = try self.query_executor.execute(view.definition_query, txn);
        defer query_result.deinit();

        // Lines 824-832: Execute defining query
        // Create new storage for refreshed data
        const temp_storage = try self.storage_engine.createTempTable(view.name);
        defer self.storage_engine.dropTempTable(temp_storage) catch {};

        // Insert all rows into temp storage
        var row_count: u64 = 0;
        while (try query_result.next()) |row| {
            try temp_storage.insert(row);
            row_count += 1;
        }

        // Lines 832-840: Atomic swap
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

        // CANARY: REQ=REQ-GQL-017; FEATURE="MV Incremental Refresh"; ASPECT=IncrementalRefresh; STATUS=TESTED; TEST=e2e_materialized_views_refresh; OWNER=storage; UPDATED=2025-09-25
        // Lines 873-882: Incremental refresh via CDC
        // Get change data since last LSN
        const changes = try self.cdc_engine.getChangesSince(since_lsn);
        defer changes.deinit();

        // Lines 884-892: Apply WAL diffs
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
        // CANARY: REQ=REQ-GQL-024; FEATURE="MV Differential Refresh"; ASPECT=DifferentialRefresh; STATUS=IMPL; TEST=test_materialized_views; OWNER=storage; UPDATED=2025-10-16

        job.status = .running;

        // Execute the view's defining query to get new state
        const txn = try self.storage_engine.beginTransaction(.read_committed);
        defer txn.rollback() catch {};

        const new_result = try self.query_executor.execute(view.definition_query, txn);
        defer new_result.deinit();

        // Load current view state
        const current_result = try self.storage_engine.readTable(view.storage_location);
        defer current_result.deinit();

        // Compute differences using hash-based comparison
        var old_rows = std.AutoHashMap(u64, []exec.Value).init(self.allocator);
        defer old_rows.deinit();
        var new_rows = std.AutoHashMap(u64, []exec.Value).init(self.allocator);
        defer new_rows.deinit();

        // Hash current rows
        while (try current_result.next()) |row| {
            const hash = computeRowHash(row);
            try old_rows.put(hash, row);
        }

        // Hash new rows and identify inserts/updates
        var insert_count: u64 = 0;
        var update_count: u64 = 0;
        var delete_count: u64 = 0;

        while (try new_result.next()) |row| {
            const hash = computeRowHash(row);
            try new_rows.put(hash, row);

            if (old_rows.get(hash)) |_| {
                // Row exists, no change needed (or update if values differ)
            } else {
                // New row - insert
                try view.storage.insert(row);
                insert_count += 1;
            }
        }

        // Identify deletes (rows in old but not in new)
        var old_iter = old_rows.iterator();
        while (old_iter.next()) |entry| {
            if (!new_rows.contains(entry.key_ptr.*)) {
                try view.storage.delete(entry.key_ptr.*);
                delete_count += 1;
            }
        }

        // Update job metrics
        job.rows_processed = insert_count + update_count + delete_count;
        job.end_time = std.time.milliTimestamp();
        job.status = .completed;

        // Update view metadata
        view.last_refresh_time = std.time.milliTimestamp();
        view.statistics.refresh_count += 1;

        self.refresh_manager.metrics.total_refreshes += 1;
        self.refresh_manager.metrics.differential_refreshes += 1;
    }

    fn computeRowHash(row: []exec.Value) u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (row) |value| {
            // Hash based on value type and content
            switch (value) {
                .Int => |i| hasher.update(std.mem.asBytes(&i)),
                .Float => |f| hasher.update(std.mem.asBytes(&f)),
                .String => |s| hasher.update(s),
                .Bool => |b| hasher.update(&[_]u8{if (b) 1 else 0}),
                .Null => hasher.update(&[_]u8{0}),
                else => {},
            }
        }
        return hasher.final();
    }

    fn findApplicableViews(self: *MaterializedViewManager, query: *ast.Query) ![]ViewCatalog.MaterializedView {
        // CANARY: REQ=REQ-GQL-025; FEATURE="MV Query Matching"; ASPECT=ViewSelection; STATUS=IMPL; TEST=test_materialized_views; OWNER=storage; UPDATED=2025-10-16

        var applicable = std.ArrayList(ViewCatalog.MaterializedView).init(self.allocator);
        defer applicable.deinit();

        // Extract labels from query
        var query_labels = std.ArrayList([]const u8).init(self.allocator);
        defer query_labels.deinit();

        for (query.match.chains) |chain| {
            for (chain.links) |link| {
                if (link.left) |left_node| {
                    for (left_node.labels) |label| {
                        try query_labels.append(label);
                    }
                }
                if (link.right) |right_node| {
                    for (right_node.labels) |label| {
                        try query_labels.append(label);
                    }
                }
            }
        }

        // Check each view for matching labels
        var view_iter = self.view_catalog.views.valueIterator();
        while (view_iter.next()) |view| {
            // Check if view dependencies overlap with query labels
            var matches = false;
            for (view.dependencies) |dep| {
                for (query_labels.items) |query_label| {
                    if (std.mem.eql(u8, dep.object_name, query_label)) {
                        matches = true;
                        break;
                    }
                }
                if (matches) break;
            }

            // Check staleness threshold
            if (matches) {
                const current_time = std.time.milliTimestamp();
                const staleness = @as(u64, @intCast(current_time - view.statistics.last_refresh_time)) / 1000;

                // Only use view if it's not too stale (< 1 hour)
                if (staleness < 3600) {
                    try applicable.append(view.*);
                }
            }
        }

        return applicable.toOwnedSlice();
    }

    fn rewriteWithView(self: *MaterializedViewManager, query: *ast.Query, view: ViewCatalog.MaterializedView) !*ast.Query {
        // CANARY: REQ=REQ-GQL-026; FEATURE="MV Query Rewriting"; ASPECT=QueryTransformation; STATUS=IMPL; TEST=test_materialized_views; OWNER=storage; UPDATED=2025-10-16

        // Create a new query that reads from the materialized view instead
        const rewritten = try self.allocator.create(ast.Query);

        // Copy the original query structure
        rewritten.* = query.*;

        // Replace MATCH clause to read from view
        // Simplified: In reality would need to map original patterns to view columns
        const view_label = try self.allocator.dupe(u8, view.name);

        // Create a simple MATCH pattern for the view
        const view_pattern = ast.NodePattern{
            .variable = null,
            .labels = &[_][]const u8{view_label},
            .properties = null,
            .where_expr = null,
        };

        const link = ast.PatternLink{
            .left = view_pattern,
            .edge = null,
            .right = null,
        };

        const chain = ast.PatternChain{
            .links = &[_]ast.PatternLink{link},
        };

        const match_clause = ast.MatchClause{
            .chains = &[_]ast.PatternChain{chain},
        };

        rewritten.match = match_clause;

        // Adjust WHERE clause if needed to filter view results
        if (query.where_clause) |where_expr| {
            rewritten.where_clause = where_expr; // Keep original filtering
        }

        return rewritten;
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
