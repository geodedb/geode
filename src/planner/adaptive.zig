const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast.zig");
const planner = @import("../planner.zig");
const exec = @import("../exec.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Planner; STATUS=EXEMPT; OWNER=planner; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("planner");
const Attr = logging.Attr;

// Adaptive Query Execution with runtime statistics and plan caching
pub const AdaptiveQueryExecutor = struct {
    allocator: Allocator,
    plan_cache: PlanCache,
    statistics_collector: StatisticsCollector,
    runtime_optimizer: RuntimeOptimizer,
    query_history: QueryHistory,
    adaptive_config: AdaptiveConfig,

    const Self = @This();

    pub const AdaptiveConfig = struct {
        enable_adaptive_execution: bool = true,
        enable_plan_caching: bool = true,
        enable_runtime_reoptimization: bool = true,
        enable_statistics_feedback: bool = true,
        cache_size_mb: u32 = 256,
        statistics_sample_rate: f32 = 0.01,
        reoptimization_threshold: f32 = 2.0, // Re-optimize if actual > 2x estimated
        parallel_threshold_rows: u64 = 10000,
        max_parallel_degree: u32 = 8,
    };

    pub const PlanCache = struct {
        allocator: Allocator,
        cache: std.hash_map.HashMap(PlanCacheKey, CachedPlan, PlanCacheKey.hash, PlanCacheKey.eql, 80),
        total_size_bytes: u64,
        max_size_bytes: u64,
        hit_count: u64,
        miss_count: u64,
        eviction_count: u64,

        pub const PlanCacheKey = struct {
            query_text_hash: u64,
            parameter_types_hash: u64,
            session_context_hash: u64,

            pub fn hash(self: PlanCacheKey) u64 {
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(std.mem.asBytes(&self.query_text_hash));
                hasher.update(std.mem.asBytes(&self.parameter_types_hash));
                hasher.update(std.mem.asBytes(&self.session_context_hash));
                return hasher.final();
            }

            pub fn eql(a: PlanCacheKey, b: PlanCacheKey) bool {
                return a.query_text_hash == b.query_text_hash and
                    a.parameter_types_hash == b.parameter_types_hash and
                    a.session_context_hash == b.session_context_hash;
            }
        };

        pub const CachedPlan = struct {
            plan: *planner.PhysicalPlan,
            statistics: PlanStatistics,
            compilation_time_ms: u64,
            last_used: i64,
            use_count: u64,
            avg_execution_time_ms: f64,
            parameter_sensitivity: ParameterSensitivity,
        };

        pub const PlanStatistics = struct {
            estimated_rows: u64,
            estimated_cost: f64,
            estimated_memory_bytes: u64,
            actual_rows_history: std.ArrayList(u64),
            actual_time_history: std.ArrayList(u64),
            confidence_score: f32,
        };

        pub const ParameterSensitivity = struct {
            is_sensitive: bool,
            sensitivity_factors: []const u8,
            recompilation_hints: []const u8,
        };
    };

    pub const StatisticsCollector = struct {
        allocator: Allocator,
        table_stats: std.StringHashMap(TableStatistics),
        column_stats: std.StringHashMap(ColumnStatistics),
        index_stats: std.StringHashMap(IndexStatistics),
        correlation_stats: std.ArrayList(CorrelationStatistic),
        sample_reservoir: SampleReservoir,

        pub const TableStatistics = struct {
            row_count: u64,
            page_count: u64,
            avg_row_size: u64,
            null_fraction: f32,
            distinct_values: u64,
            most_common_values: []Value,
            histogram: ?Histogram,
            last_analyzed: i64,
            modification_counter: u64,
        };

        pub const ColumnStatistics = struct {
            null_count: u64,
            distinct_count: u64,
            min_value: ?Value,
            max_value: ?Value,
            avg_width: u32,
            correlation: f32,
            most_common_vals: []Value,
            most_common_freqs: []f32,
            histogram_bounds: ?[]Value,
            n_distinct: f32,
        };

        pub const IndexStatistics = struct {
            unique_keys: u64,
            height: u32,
            leaf_pages: u64,
            internal_pages: u64,
            empty_pages: u64,
            deleted_entries: u64,
            avg_leaf_density: f32,
            fragmentation: f32,
            correlation: f32,
        };

        pub const CorrelationStatistic = struct {
            column1: []const u8,
            column2: []const u8,
            correlation_coefficient: f32,
            mutual_information: f32,
            functional_dependency: f32,
        };

        pub const Histogram = struct {
            buckets: []HistogramBucket,
            total_values: u64,
            null_values: u64,

            pub const HistogramBucket = struct {
                lower_bound: Value,
                upper_bound: Value,
                frequency: u64,
                distinct_values: u64,
            };
        };

        pub const SampleReservoir = struct {
            samples: []Sample,
            max_samples: u64,
            total_seen: u64,

            pub const Sample = struct {
                value: Value,
                weight: f32,
                timestamp: i64,
            };
        };

        pub const Value = union(enum) {
            null,
            bool: bool,
            int: i64,
            float: f64,
            string: []const u8,
            bytes: []const u8,
        };
    };

    pub const RuntimeOptimizer = struct {
        allocator: Allocator,
        monitoring_state: MonitoringState,
        adaptation_rules: []AdaptationRule,
        feedback_processor: FeedbackProcessor,

        pub const MonitoringState = struct {
            current_executions: std.ArrayList(ExecutionMonitor),
            memory_usage: u64,
            cpu_usage: f32,
            io_stats: IOStatistics,
        };

        pub const ExecutionMonitor = struct {
            query_id: u64,
            start_time: i64,
            estimated_rows: u64,
            actual_rows: u64,
            estimated_cost: f64,
            actual_cost: f64,
            memory_used: u64,
            spill_count: u32,
            reoptimization_triggered: bool,
        };

        pub const IOStatistics = struct {
            reads: u64,
            writes: u64,
            cache_hits: u64,
            cache_misses: u64,
            sequential_scans: u64,
            index_scans: u64,
        };

        pub const AdaptationRule = struct {
            condition: AdaptationCondition,
            action: AdaptationAction,
            priority: u32,

            pub const AdaptationCondition = union(enum) {
                cardinality_error: struct {
                    threshold_ratio: f32,
                },
                memory_pressure: struct {
                    threshold_bytes: u64,
                },
                skew_detected: struct {
                    skew_factor: f32,
                },
                slow_progress: struct {
                    time_threshold_ms: u64,
                },
            };

            pub const AdaptationAction = union(enum) {
                reoptimize,
                change_join_algorithm,
                enable_parallelism,
                spill_to_disk,
                adjust_memory_grant,
            };
        };

        pub const FeedbackProcessor = struct {
            allocator: Allocator,
            feedback_history: std.ArrayList(QueryFeedback),
            learning_rate: f32,

            pub const QueryFeedback = struct {
                query_hash: u64,
                estimated_stats: Statistics,
                actual_stats: Statistics,
                plan_adjustments: []PlanAdjustment,

                pub const Statistics = struct {
                    row_count: u64,
                    execution_time_ms: u64,
                    memory_bytes: u64,
                    cpu_cycles: u64,
                };

                pub const PlanAdjustment = struct {
                    operator_id: u64,
                    adjustment_type: enum {
                        selectivity,
                        cost_model,
                        parallelism,
                        memory_grant,
                    },
                    old_value: f64,
                    new_value: f64,
                };
            };
        };
    };

    pub const QueryHistory = struct {
        allocator: Allocator,
        queries: std.ArrayList(HistoricalQuery),
        patterns: std.ArrayList(QueryPattern),
        workload_analyzer: WorkloadAnalyzer,

        pub const HistoricalQuery = struct {
            query_text: []const u8,
            execution_count: u64,
            avg_execution_time: f64,
            min_execution_time: u64,
            max_execution_time: u64,
            last_executed: i64,
            access_pattern: AccessPattern,
        };

        pub const QueryPattern = struct {
            pattern_type: PatternType,
            frequency: u64,
            tables: []const u8,
            predicates: []PredicatePattern,

            pub const PatternType = enum {
                point_query,
                range_scan,
                full_scan,
                join_heavy,
                aggregation_heavy,
                mixed,
            };

            pub const PredicatePattern = struct {
                column: []const u8,
                operator: []const u8,
                selectivity: f32,
            };
        };

        pub const AccessPattern = struct {
            read_write_ratio: f32,
            temporal_locality: f32,
            spatial_locality: f32,
            access_frequency: []AccessFrequency,

            pub const AccessFrequency = struct {
                hour: u8,
                frequency: u64,
            };
        };

        pub const WorkloadAnalyzer = struct {
            workload_type: WorkloadType,
            peak_hours: []u8,
            resource_usage: ResourceUsage,
            optimization_opportunities: []OptimizationOpportunity,

            pub const WorkloadType = enum {
                oltp,
                olap,
                hybrid,
                batch,
                streaming,
            };

            pub const ResourceUsage = struct {
                cpu_bound: bool,
                memory_bound: bool,
                io_bound: bool,
                network_bound: bool,
            };

            pub const OptimizationOpportunity = struct {
                opportunity_type: enum {
                    missing_index,
                    redundant_index,
                    statistics_stale,
                    plan_regression,
                    parameter_sniffing,
                },
                impact_score: f32,
                recommendation: []const u8,
            };
        };
    };

    pub fn init(allocator: Allocator, config: AdaptiveConfig) !AdaptiveQueryExecutor {
        return AdaptiveQueryExecutor{
            .allocator = allocator,
            .plan_cache = try initPlanCache(allocator, config.cache_size_mb),
            .statistics_collector = try initStatisticsCollector(allocator),
            .runtime_optimizer = try initRuntimeOptimizer(allocator),
            .query_history = try initQueryHistory(allocator),
            .adaptive_config = config,
        };
    }

    pub fn deinit(self: *AdaptiveQueryExecutor) void {
        self.plan_cache.cache.deinit();
        self.statistics_collector.table_stats.deinit();
        self.statistics_collector.column_stats.deinit();
        self.statistics_collector.index_stats.deinit();
        self.query_history.queries.deinit();
    }

    pub fn executeAdaptive(
        self: *AdaptiveQueryExecutor,
        query: []const u8,
        params: []const exec.Parameter,
        context: exec.ExecutionContext,
    ) !exec.QueryResult {
        const start_time = std.time.milliTimestamp();

        // Check plan cache
        const cache_key = computeCacheKey(query, params, context);
        if (self.plan_cache.cache.get(cache_key)) |cached| {
            self.plan_cache.hit_count += 1;

            // Validate if cached plan is still good
            if (try self.validateCachedPlan(cached, params)) {
                return self.executeCachedPlan(cached.plan, params, context);
            }
        } else {
            self.plan_cache.miss_count += 1;
        }

        // Parse and optimize query
        const parsed = try ast.parse(self.allocator, query);
        defer parsed.deinit();

        // Generate initial plan with statistics
        var initial_plan = try self.generateOptimalPlan(parsed, params, context);

        // Set up runtime monitoring
        const monitor = try self.runtime_optimizer.startMonitoring(&initial_plan);
        defer monitor.stop();

        // Execute with adaptive optimization
        var result = try self.executeWithAdaptation(&initial_plan, params, context, monitor);

        // Collect feedback
        try self.collectExecutionFeedback(query, &initial_plan, &result, monitor);

        // Update cache
        if (self.adaptive_config.enable_plan_caching) {
            try self.updatePlanCache(cache_key, &initial_plan, monitor.getStatistics());
        }

        // Update query history
        const execution_time = std.time.milliTimestamp() - start_time;
        try self.updateQueryHistory(query, execution_time, &result);

        return result;
    }

    fn generateOptimalPlan(
        self: *AdaptiveQueryExecutor,
        parsed: *ast.Query,
        params: []const exec.Parameter,
        context: exec.ExecutionContext,
    ) !planner.PhysicalPlan {
        _ = params;
        _ = context;

        // Use statistics to generate cost-based plan
        var logical_plan = try planner.generateLogicalPlan(self.allocator, parsed);

        // Apply cost-based optimization
        const statistics = try self.gatherRelevantStatistics(&logical_plan);
        var cost_model = CostModel.init(self.allocator, statistics);

        // Enumerate plan alternatives
        var alternatives = try self.enumeratePlanAlternatives(&logical_plan);
        defer alternatives.deinit();

        // Choose best plan based on cost
        var best_plan: ?planner.PhysicalPlan = null;
        var best_cost: f64 = std.math.inf(f64);

        for (alternatives.items) |alternative| {
            const cost = try cost_model.estimateCost(&alternative);
            if (cost < best_cost) {
                best_cost = cost;
                best_plan = alternative;
            }
        }

        return best_plan orelse error.NoPlanGenerated;
    }

    fn executeWithAdaptation(
        self: *AdaptiveQueryExecutor,
        plan: *planner.PhysicalPlan,
        params: []const exec.Parameter,
        context: exec.ExecutionContext,
        monitor: *RuntimeOptimizer.ExecutionMonitor,
    ) !exec.QueryResult {
        var executor = exec.Executor.init(self.allocator, context);
        defer executor.deinit();

        // Set up adaptive hooks
        executor.setProgressCallback(adaptiveProgressCallback);
        executor.setUserData(self);

        // Start execution
        var result = try executor.execute(plan, params);

        // Check for reoptimization opportunities during execution
        if (self.adaptive_config.enable_runtime_reoptimization) {
            const should_reoptimize = try self.checkReoptimizationTriggers(monitor);

            if (should_reoptimize) {
                log.info("Triggering runtime reoptimization", &.{});

                // Generate new plan based on actual statistics
                const new_plan = try self.reoptimizeWithActualStats(plan, monitor);

                // Continue execution with new plan
                result = try executor.execute(&new_plan, params);
            }
        }

        return result;
    }

    fn adaptiveProgressCallback(ctx: *anyopaque, progress: exec.ExecutionProgress) void {
        const self = @ptrCast(*AdaptiveQueryExecutor, @alignCast(@alignOf(AdaptiveQueryExecutor), ctx));

        // Check memory pressure
        if (progress.memory_used > self.adaptive_config.memory_limit) {
            progress.spill_to_disk = true;
        }

        // Check for data skew
        if (progress.partition_skew > 0.3) {
            progress.rebalance_partitions = true;
        }

        // Adjust parallelism dynamically
        if (progress.rows_processed > self.adaptive_config.parallel_threshold_rows) {
            progress.parallel_degree = @min(
                self.adaptive_config.max_parallel_degree,
                progress.suggested_parallel_degree,
            );
        }
    }

    fn collectExecutionFeedback(
        self: *AdaptiveQueryExecutor,
        query: []const u8,
        plan: *planner.PhysicalPlan,
        result: *exec.QueryResult,
        monitor: *RuntimeOptimizer.ExecutionMonitor,
    ) !void {
        const feedback = RuntimeOptimizer.FeedbackProcessor.QueryFeedback{
            .query_hash = std.hash.Wyhash.hash(0, query),
            .estimated_stats = .{
                .row_count = plan.estimated_rows,
                .execution_time_ms = plan.estimated_time_ms,
                .memory_bytes = plan.estimated_memory,
                .cpu_cycles = plan.estimated_cpu_cycles,
            },
            .actual_stats = .{
                .row_count = result.row_count,
                .execution_time_ms = monitor.getExecutionTime(),
                .memory_bytes = monitor.memory_used,
                .cpu_cycles = monitor.getCPUCycles(),
            },
            .plan_adjustments = try self.computePlanAdjustments(plan, monitor),
        };

        try self.runtime_optimizer.feedback_processor.feedback_history.append(feedback);

        // Update statistics based on feedback
        if (self.adaptive_config.enable_statistics_feedback) {
            try self.updateStatisticsFromFeedback(feedback);
        }
    }

    // Helper functions
    fn initPlanCache(allocator: Allocator, cache_size_mb: u32) !PlanCache {
        return PlanCache{
            .allocator = allocator,
            .cache = std.hash_map.HashMap(PlanCache.PlanCacheKey, PlanCache.CachedPlan, PlanCache.PlanCacheKey.hash, PlanCache.PlanCacheKey.eql, 80).init(allocator),
            .total_size_bytes = 0,
            .max_size_bytes = cache_size_mb * 1024 * 1024,
            .hit_count = 0,
            .miss_count = 0,
            .eviction_count = 0,
        };
    }

    fn initStatisticsCollector(allocator: Allocator) !StatisticsCollector {
        return StatisticsCollector{
            .allocator = allocator,
            .table_stats = std.StringHashMap(StatisticsCollector.TableStatistics).init(allocator),
            .column_stats = std.StringHashMap(StatisticsCollector.ColumnStatistics).init(allocator),
            .index_stats = std.StringHashMap(StatisticsCollector.IndexStatistics).init(allocator),
            .correlation_stats = std.ArrayList(StatisticsCollector.CorrelationStatistic).init(allocator),
            .sample_reservoir = .{
                .samples = try allocator.alloc(StatisticsCollector.SampleReservoir.Sample, 10000),
                .max_samples = 10000,
                .total_seen = 0,
            },
        };
    }

    fn initRuntimeOptimizer(allocator: Allocator) !RuntimeOptimizer {
        const rules = try allocator.alloc(RuntimeOptimizer.AdaptationRule, 5);
        rules[0] = .{
            .condition = .{ .cardinality_error = .{ .threshold_ratio = 2.0 } },
            .action = .reoptimize,
            .priority = 1,
        };
        rules[1] = .{
            .condition = .{ .memory_pressure = .{ .threshold_bytes = 1024 * 1024 * 1024 } },
            .action = .spill_to_disk,
            .priority = 2,
        };

        return RuntimeOptimizer{
            .allocator = allocator,
            .monitoring_state = .{
                .current_executions = std.ArrayList(RuntimeOptimizer.ExecutionMonitor).init(allocator),
                .memory_usage = 0,
                .cpu_usage = 0.0,
                .io_stats = .{
                    .reads = 0,
                    .writes = 0,
                    .cache_hits = 0,
                    .cache_misses = 0,
                    .sequential_scans = 0,
                    .index_scans = 0,
                },
            },
            .adaptation_rules = rules,
            .feedback_processor = .{
                .allocator = allocator,
                .feedback_history = std.ArrayList(RuntimeOptimizer.FeedbackProcessor.QueryFeedback).init(allocator),
                .learning_rate = 0.1,
            },
        };
    }

    fn initQueryHistory(allocator: Allocator) !QueryHistory {
        return QueryHistory{
            .allocator = allocator,
            .queries = std.ArrayList(QueryHistory.HistoricalQuery).init(allocator),
            .patterns = std.ArrayList(QueryHistory.QueryPattern).init(allocator),
            .workload_analyzer = .{
                .workload_type = .hybrid,
                .peak_hours = try allocator.alloc(u8, 0),
                .resource_usage = .{
                    .cpu_bound = false,
                    .memory_bound = false,
                    .io_bound = false,
                    .network_bound = false,
                },
                .optimization_opportunities = try allocator.alloc(QueryHistory.WorkloadAnalyzer.OptimizationOpportunity, 0),
            },
        };
    }

    fn computeCacheKey(query: []const u8, params: []const exec.Parameter, context: exec.ExecutionContext) PlanCache.PlanCacheKey {
        var query_hasher = std.hash.Wyhash.init(0);
        query_hasher.update(query);

        var param_hasher = std.hash.Wyhash.init(0);
        for (params) |param| {
            param_hasher.update(std.mem.asBytes(&param.type));
        }

        var context_hasher = std.hash.Wyhash.init(0);
        context_hasher.update(std.mem.asBytes(&context));

        return .{
            .query_text_hash = query_hasher.final(),
            .parameter_types_hash = param_hasher.final(),
            .session_context_hash = context_hasher.final(),
        };
    }

    const CostModel = struct {
        allocator: Allocator,
        statistics: *StatisticsCollector,

        fn init(allocator: Allocator, statistics: *StatisticsCollector) CostModel {
            return .{
                .allocator = allocator,
                .statistics = statistics,
            };
        }

        fn estimateCost(self: *CostModel, plan: *planner.PhysicalPlan) !f64 {
            _ = self;
            // Simplified cost estimation
            return @intToFloat(f64, plan.estimated_rows) * 0.01 +
                @intToFloat(f64, plan.estimated_memory) * 0.001;
        }
    };
};
