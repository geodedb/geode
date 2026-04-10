const std = @import("std");
const ast = @import("../gql/ast.zig");
const cbo = @import("../planner/cbo.zig");

// Distributed query planning for federation-aware query optimization
pub const DistributedQueryPlanner = struct {
    allocator: std.mem.Allocator,
    federation_manager: *FederationManager,
    shard_registry: ShardRegistry,
    cost_model: DistributedCostModel,
    stats_registry: ?*cbo.StatsRegistry = null,

    pub fn init(allocator: std.mem.Allocator, federation_manager: *FederationManager) DistributedQueryPlanner {
        return .{
            .allocator = allocator,
            .federation_manager = federation_manager,
            .shard_registry = ShardRegistry.init(allocator),
            .cost_model = DistributedCostModel.init(),
        };
    }

    /// Set the CBO statistics registry for data-driven row estimation
    pub fn setStatsRegistry(self: *DistributedQueryPlanner, registry: *cbo.StatsRegistry) void {
        self.stats_registry = registry;
    }

    pub fn deinit(self: *DistributedQueryPlanner) void {
        self.shard_registry.deinit();
    }

    // Plan distributed query execution across federation shards
    // CANARY: REQ=REQ-DIST-PLAN-001; FEATURE="DistributedQueryPlanning"; ASPECT=Orchestration; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-01
    pub fn planDistributedQuery(self: *DistributedQueryPlanner, query: *const ast.Query) !DistributedPlan {
        // Analyze query for distribution opportunities
        const distribution_analysis = try self.analyzeQueryDistribution(query);

        // Generate shard-specific subqueries
        const shard_plans = try self.generateShardPlans(query, distribution_analysis);

        // Plan coordinator operations (joins, aggregations, unions)
        const coordinator_plan = try self.planCoordinatorOperations(query, shard_plans);

        // Optimize inter-shard communication
        const optimized_plan = try self.optimizeInterShardCommunication(coordinator_plan);

        return optimized_plan;
    }

    // Analyze query patterns for optimal distribution strategy
    fn analyzeQueryDistribution(self: *DistributedQueryPlanner, query: *const ast.Query) !DistributionAnalysis {
        var analysis = DistributionAnalysis.init(self.allocator);

        // Extract label affinities and edge patterns from MATCH pattern chains
        for (query.match.chains) |chain| {
            for (chain.hops) |hop| {
                // Node labels
                for (hop.left.labels) |label| {
                    try analysis.addLabelAffinity(label);
                }
                for (hop.right.labels) |label| {
                    try analysis.addLabelAffinity(label);
                }
                // Node properties
                if (hop.left.props) |props| {
                    try analysis.addPropertyFilters(props);
                }
                if (hop.right.props) |props| {
                    try analysis.addPropertyFilters(props);
                }
                // Edge/relationship type patterns
                try analysis.addEdgePattern(hop.rel);
            }
            // Standalone head node (single-node chain with no hops)
            if (chain.head) |head| {
                for (head.labels) |label| {
                    try analysis.addLabelAffinity(label);
                }
                if (head.props) |props| {
                    try analysis.addPropertyFilters(props);
                }
            }
        }

        // Analyze WHERE clause for filter-based shard routing
        if (query.where_clause) |where| {
            try self.analyzeWhereClause(&analysis, where);
        }

        return analysis;
    }

    // Generate optimized plans for each participating shard.
    // Uses label-based routing: if the query references specific labels and
    // shards advertise labels, only target shards whose labels overlap.
    // Falls back to all registered shards (or shard IDs 1,2 if registry is empty).
    fn generateShardPlans(self: *DistributedQueryPlanner, query: *const ast.Query, analysis: DistributionAnalysis) ![]ShardPlan {
        var shard_plans = std.ArrayList(ShardPlan).initCapacity(self.allocator, 4) catch return error.OutOfMemory;

        // Collect participating shard IDs from the registry
        const participating = try self.selectParticipatingShards(analysis);
        defer self.allocator.free(participating);

        for (participating) |shard_id| {
            const shard_query = try self.generateShardQuery(query, shard_id, analysis);
            const local_plan = try self.optimizeShardLocalPlan(shard_query, shard_id);

            try shard_plans.append(self.allocator, ShardPlan{
                .shard_id = shard_id,
                .query = shard_query,
                .local_plan = local_plan,
                .estimated_rows = self.estimateShardRows(shard_id, analysis),
                .estimated_cost = self.cost_model.estimateShardCost(local_plan),
                .data_transfer_size = self.estimateDataTransfer(local_plan),
            });
        }

        return shard_plans.toOwnedSlice(self.allocator);
    }

    // CANARY: REQ=REQ-DIST-PLAN-004; FEATURE="ShardPruning"; ASPECT=QueryRouting; STATUS=IMPL; TEST=query_planner.selectParticipatingShards; OWNER=distributed; UPDATED=2026-04-01
    /// Select which shards participate in a query based on label affinity.
    /// If the analysis specifies labels and shards advertise matching labels,
    /// only those shards are included (shard pruning). Otherwise all shards
    /// participate.
    fn selectParticipatingShards(self: *DistributedQueryPlanner, analysis: DistributionAnalysis) ![]u32 {
        const registry_count = self.shard_registry.shards.count();

        // If registry is empty, use default shard IDs for backward compatibility
        if (registry_count == 0) {
            var defaults = try self.allocator.alloc(u32, 2);
            defaults[0] = 1;
            defaults[1] = 2;
            return defaults;
        }

        const has_label_affinities = analysis.label_affinities.count() > 0;

        // Try label-based pruning: only include shards whose labels
        // overlap with the query's label affinities.
        if (has_label_affinities) {
            var pruned = std.ArrayList(u32).init(self.allocator);
            var shard_iter = self.shard_registry.shards.iterator();
            while (shard_iter.next()) |entry| {
                const shard_info = entry.value_ptr.*;
                if (shardMatchesLabels(shard_info, analysis)) {
                    try pruned.append(self.allocator, entry.key_ptr.*);
                }
            }
            // If pruning produced results, use them; otherwise fall through to all shards
            if (pruned.items.len > 0) {
                return pruned.toOwnedSlice(self.allocator);
            }
            pruned.deinit(self.allocator);
        }

        // No pruning possible: include all shards
        var all_ids = try self.allocator.alloc(u32, registry_count);
        var it = self.shard_registry.shards.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            all_ids[i] = entry.key_ptr.*;
        }
        return all_ids;
    }

    /// Check whether a shard's advertised labels overlap with the query's label affinities.
    fn shardMatchesLabels(shard_info: ShardInfo, analysis: DistributionAnalysis) bool {
        for (shard_info.labels) |shard_label| {
            if (analysis.label_affinities.get(shard_label) != null) {
                return true;
            }
        }
        return false;
    }

    // Plan coordinator operations for distributed execution
    fn planCoordinatorOperations(self: *DistributedQueryPlanner, query: *const ast.Query, shard_plans: []const ShardPlan) !CoordinatorPlan {
        var coordinator_plan = CoordinatorPlan.init(self.allocator);

        // Store shard plans for downstream data flow analysis
        coordinator_plan.shard_plans = shard_plans;

        // Plan distributed joins
        if (self.requiresDistributedJoin(query)) {
            coordinator_plan.join_strategy = try self.planDistributedJoin(query, shard_plans);
        }

        // Plan distributed aggregations (check for aggregation functions in RETURN items)
        if (self.hasAggregationFunctions(query)) {
            coordinator_plan.aggregation_strategy = try self.planDistributedAggregation(query, shard_plans);
        }

        // Plan distributed sorting
        if (query.order_by) |order| {
            coordinator_plan.sort_strategy = try self.planDistributedSort(order, shard_plans);
        }

        // Plan distributed UNION operations
        if (self.requiresDistributedUnion(query)) {
            coordinator_plan.union_strategy = try self.planDistributedUnion(query, shard_plans);
        }

        return coordinator_plan;
    }

    // Optimize communication patterns between shards and coordinator
    fn optimizeInterShardCommunication(self: *DistributedQueryPlanner, plan: CoordinatorPlan) !DistributedPlan {
        // Analyze data flow patterns
        const data_flow = try self.analyzeDataFlow(plan);

        // Optimize network transfer strategies
        const transfer_optimization = try self.optimizeDataTransfer(data_flow);

        // Plan parallel execution phases
        const execution_phases = try self.planExecutionPhases(plan, transfer_optimization);

        // Estimate total execution cost
        const total_cost = self.cost_model.estimateTotalCost(plan, transfer_optimization);

        return DistributedPlan{
            .coordinator_plan = plan,
            .data_flow = data_flow,
            .transfer_optimization = transfer_optimization,
            .execution_phases = execution_phases,
            .estimated_cost = total_cost,
            .parallelism_level = self.determineOptimalParallelism(plan),
        };
    }

    // Analyze WHERE clause for shard-specific filtering
    fn analyzeWhereClause(self: *DistributedQueryPlanner, analysis: *DistributionAnalysis, where: ast.Expr) !void {
        switch (where) {
            .Binary => |bin| {
                // Recurse into AND conjuncts to extract all filter conditions
                if (bin.op == .And) {
                    try self.analyzeWhereClause(analysis, bin.left.*);
                    try self.analyzeWhereClause(analysis, bin.right.*);
                } else if (bin.op == .Eq or bin.op == .Ne or bin.op == .Lt or
                    bin.op == .Le or bin.op == .Gt or bin.op == .Ge)
                {
                    // Analyze comparison operations for shard filtering
                    try analysis.addFilterCondition(bin);
                }
            },
            .Call => |call| {
                // Analyze function calls for geographic or hash-based sharding
                try analysis.addFunctionFilter(call);
            },
            else => {},
        }
    }

    // Helper methods for distributed optimization
    fn requiresDistributedJoin(self: *DistributedQueryPlanner, query: *const ast.Query) bool {
        _ = self;
        // Check if query involves cross-shard relationships
        return query.match.chains.len > 1;
    }

    fn requiresDistributedUnion(self: *DistributedQueryPlanner, query: *const ast.Query) bool {
        _ = self;
        // A query with multiple match chains and no explicit join conditions
        // may benefit from UNION-style distributed execution
        return query.match.chains.len > 2;
    }

    /// Estimate row count for a shard using CBO statistics when available.
    /// Falls back to a default heuristic (1000 rows) when no stats exist.
    // CANARY: REQ=REQ-DIST-PLAN-002; FEATURE="ShardRowEstimation"; ASPECT=CBO; STATUS=IMPL; TEST=query_planner.estimateShardRows; OWNER=distributed; UPDATED=2026-04-01
    pub fn estimateShardRows(self: *DistributedQueryPlanner, shard_id: u32, analysis: DistributionAnalysis) usize {
        // Try CBO statistics for each label that has shard affinity
        if (self.stats_registry) |registry| {
            var it = analysis.label_affinities.iterator();
            while (it.next()) |entry| {
                if (registry.getTableStats(entry.key_ptr.*)) |stats| {
                    const total_shards = @max(1, self.shard_registry.shards.count());
                    var rows_per_shard = stats.row_count / total_shards;

                    // If the shard has estimated_size metadata, weight proportionally
                    if (self.shard_registry.shards.get(shard_id)) |shard_info| {
                        if (shard_info.estimated_size > 0) {
                            // Compute total estimated size across all shards
                            var total_size: usize = 0;
                            var shard_iter = self.shard_registry.shards.iterator();
                            while (shard_iter.next()) |se| {
                                total_size += se.value_ptr.estimated_size;
                            }
                            if (total_size > 0) {
                                // Weight this shard's share by its fraction of total size
                                rows_per_shard = stats.row_count * shard_info.estimated_size / total_size;
                            }
                        }
                    }

                    // Add 10% buffer for estimation variance
                    return rows_per_shard + rows_per_shard / 10;
                }
            }
        }

        // Fallback: use shard's estimated_size if available, otherwise default
        if (self.shard_registry.shards.get(shard_id)) |shard_info| {
            if (shard_info.estimated_size > 0) {
                return shard_info.estimated_size;
            }
        }

        return 1000; // Default when no statistics available
    }

    /// Estimate bytes transferred from shard to coordinator.
    /// Scales with estimated cost (proxy for row count) and operation count.
    fn estimateDataTransfer(self: *DistributedQueryPlanner, plan: ShardLocalPlan) usize {
        _ = self;
        // Base: 256 bytes per estimated cost unit (proxy for rows * avg_row_size)
        const cost_based: usize = @intFromFloat(@max(1.0, plan.estimated_cost) * 256.0);
        // Minimum 1KB, capped at 100MB
        return @min(100 * 1024 * 1024, @max(1024, cost_based));
    }

    pub fn determineOptimalParallelism(self: *DistributedQueryPlanner, plan: CoordinatorPlan) u8 {
        _ = self;
        // Determine optimal parallelism based on shard count and operation complexity
        const shard_count = plan.target_shards.items.len;
        return @min(@as(u8, @intCast(shard_count)), 8); // Max 8 parallel operations
    }

    // CANARY: REQ=REQ-DIST-PLAN-003; FEATURE="ShardQueryGeneration"; ASPECT=QueryRouting; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-05
    /// Generate a shard-scoped query. Currently returns a copy of the original
    /// query annotated with the target shard ID for downstream routing.
    /// Label-based routing is delegated to `selectParticipatingShards`; this
    /// function preserves the full query AST so the shard executor receives a
    /// valid query tree. Future work: inject shard-scoped WHERE predicates.
    fn generateShardQuery(self: *DistributedQueryPlanner, query: *const ast.Query, shard_id: u32, analysis: DistributionAnalysis) !ast.Query {
        var shard_query = query.*;

        // When the shard registry has metadata for this shard, attach
        // the shard's estimated_size to the query's limit as a hint for
        // the local optimizer (only when the query has no explicit limit).
        if (self.shard_registry.shards.get(shard_id)) |shard_info| {
            // If the original query has no LIMIT and we have label affinities,
            // cap at estimated shard rows to avoid full scans on large shards.
            if (shard_query.limit == null and analysis.label_affinities.count() > 0) {
                const est = self.estimateShardRows(shard_id, analysis);
                // Only set a limit hint when the estimate is meaningful (> 0)
                if (est > 0) {
                    shard_query.limit = est;
                }
            }
            _ = shard_info; // metadata used for future predicate injection
        }

        return shard_query;
    }

    // CANARY: REQ=REQ-DIST-PLAN-005; FEATURE="ShardLocalOptimization"; ASPECT=QueryPlanning; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-05
    /// Build a local execution plan for a shard based on the query structure.
    /// Derives operations from the query AST (scan, filter, project, etc.)
    /// and estimates cost proportional to the expected rows on this shard.
    fn optimizeShardLocalPlan(self: *DistributedQueryPlanner, query: ast.Query, shard_id: u32) !ShardLocalPlan {
        // Derive operation list from query structure
        var ops = std.ArrayList(ShardLocalPlan.Operation).init(self.allocator);

        // Every query starts with a scan
        try ops.append(self.allocator, .scan);

        // If there is a WHERE clause, add a filter
        if (query.where_clause != null) {
            try ops.append(self.allocator, .filter);
        }

        // If there is a GROUP BY, add aggregation
        if (query.group_by != null) {
            try ops.append(self.allocator, .aggregate);
        }

        // If there is ORDER BY, add sort
        if (query.order_by != null) {
            try ops.append(self.allocator, .sort);
        }

        // RETURN always implies a project
        try ops.append(self.allocator, .project);

        const operations = try ops.toOwnedSlice(self.allocator);

        // Estimate cost: base cost per operation scaled by estimated data on this shard.
        // Use shard registry's estimated_size as a proxy for row count.
        const shard_size: f64 = if (self.shard_registry.shards.get(shard_id)) |info|
            @max(1.0, @as(f64, @floatFromInt(info.estimated_size)))
        else
            1000.0; // default when shard info unavailable

        // Cost = operations * base_cost * log2(shard_size) to model sub-linear scaling
        const op_count: f64 = @floatFromInt(operations.len);
        const estimated_cost = op_count * 10.0 * @log2(shard_size);

        return ShardLocalPlan{ .operations = operations, .estimated_cost = estimated_cost };
    }

    // Check if query contains aggregation functions in RETURN items
    fn hasAggregationFunctions(self: *DistributedQueryPlanner, query: *const ast.Query) bool {
        for (query.ret.items) |item| {
            if (self.isAggregationExpression(&item.expr)) {
                return true;
            }
        }
        return false;
    }

    // Check if an expression is an aggregation function call
    fn isAggregationExpression(self: *DistributedQueryPlanner, expr: *const ast.Expr) bool {
        _ = self;
        switch (expr.*) {
            .Call => |call| {
                switch (call.callee.*) {
                    .Ident => |ident| {
                        const func_name = ident.cnf;
                        return std.mem.eql(u8, func_name, "COUNT") or
                            std.mem.eql(u8, func_name, "SUM") or
                            std.mem.eql(u8, func_name, "AVG") or
                            std.mem.eql(u8, func_name, "MIN") or
                            std.mem.eql(u8, func_name, "MAX");
                    },
                    else => return false,
                }
            },
            else => return false,
        }
    }

    // CANARY: REQ=REQ-DIST-PLAN-006; FEATURE="DistributedJoin"; ASPECT=QueryPlanning; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-05
    /// Select join strategy based on shard count and estimated data volume.
    fn planDistributedJoin(self: *DistributedQueryPlanner, query: *const ast.Query, shard_plans: []const ShardPlan) !JoinStrategy {
        _ = query;
        _ = self;
        // For small number of shards, broadcast the smaller side
        if (shard_plans.len <= 2) return .broadcast_join;

        // For many shards, use shuffle join to distribute evenly
        if (shard_plans.len > 4) return .shuffle_join;

        // Default: hash join for moderate shard counts
        return .hash_join;
    }

    // CANARY: REQ=REQ-DIST-PLAN-007; FEATURE="DistributedAggregation"; ASPECT=QueryPlanning; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-05
    /// Select aggregation strategy based on query and shard topology.
    fn planDistributedAggregation(self: *DistributedQueryPlanner, query: *const ast.Query, shard_plans: []const ShardPlan) !AggregationStrategy {
        _ = self;
        // Single shard: no distributed aggregation needed
        if (shard_plans.len <= 1) return .single_phase;

        // If query has HAVING clause, need two-phase for correct filtering
        if (query.having != null) return .two_phase;

        // For many shards, streaming aggregation reduces memory
        if (shard_plans.len > 4) return .streaming;

        // Default two-phase for moderate shard counts
        return .two_phase;
    }

    // CANARY: REQ=REQ-DIST-PLAN-008; FEATURE="DistributedSort"; ASPECT=QueryPlanning; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-05
    /// Select sort strategy based on expected result set size.
    fn planDistributedSort(self: *DistributedQueryPlanner, order: ast.OrderBy, shard_plans: []const ShardPlan) !SortStrategy {
        _ = self;
        _ = order;
        // Estimate total rows across all shards
        var total_rows: usize = 0;
        for (shard_plans) |sp| {
            total_rows += sp.estimated_rows;
        }

        // For small result sets, top-k is most efficient
        if (total_rows < 1000) return .top_k;

        // For large sets, distributed sort avoids moving all data to coordinator
        if (total_rows > 100_000) return .distributed_sort;

        // Default: merge sort from pre-sorted shard results
        return .merge_sort;
    }

    // CANARY: REQ=REQ-DIST-PLAN-009; FEATURE="DistributedUnion"; ASPECT=QueryPlanning; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-05
    /// Select union strategy based on shard count and whether results need dedup.
    fn planDistributedUnion(self: *DistributedQueryPlanner, query: *const ast.Query, shard_plans: []const ShardPlan) !UnionStrategy {
        _ = self;
        // UNION DISTINCT requires batch merge for deduplication
        if (query.ret.distinct) return .batch_merge;

        // Many shards: parallel union for throughput
        if (shard_plans.len > 4) return .parallel_union;

        // Default: streaming merge for low-latency results
        return .streaming_merge;
    }

    /// Analyze data flow across shards using actual shard plan estimates.
    /// Sums data_transfer_size from all shard plans and identifies bottleneck
    /// shards (those with the highest transfer size).
    // CANARY: REQ=REQ-DIST-PLAN-010; FEATURE="DataFlowAnalysis"; ASPECT=TransferEstimation; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-10
    pub fn analyzeDataFlow(self: *DistributedQueryPlanner, plan: CoordinatorPlan) !DataFlow {
        const shard_plans = plan.shard_plans;

        // If no shard plans available, fall back to per-shard baseline
        if (shard_plans.len == 0) {
            const shard_count = @max(1, plan.target_shards.items.len);
            const estimated_per_shard: usize = 1024 * 1024; // 1MB per shard baseline
            return DataFlow{ .total_transfer = shard_count * estimated_per_shard, .bottlenecks = &.{} };
        }

        // Sum actual data_transfer_size from all shard plans
        var total_transfer: usize = 0;
        var max_transfer: usize = 0;
        var max_shard_id: u32 = 0;

        for (shard_plans) |sp| {
            total_transfer += sp.data_transfer_size;
            if (sp.data_transfer_size > max_transfer) {
                max_transfer = sp.data_transfer_size;
                max_shard_id = sp.shard_id;
            }
        }

        // Identify bottleneck shards: any shard transferring > 2x the average
        var bottleneck_list = std.ArrayList(DataFlow.Bottleneck).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        const avg_transfer = total_transfer / @max(1, shard_plans.len);

        for (shard_plans) |sp| {
            if (sp.data_transfer_size > avg_transfer * 2) {
                // Severity: ratio of this shard's transfer to the average
                const severity: f64 = @as(f64, @floatFromInt(sp.data_transfer_size)) /
                    @as(f64, @floatFromInt(@max(1, avg_transfer)));
                try bottleneck_list.append(self.allocator, DataFlow.Bottleneck{
                    .shard_id = sp.shard_id,
                    .operation = "data_transfer",
                    .severity = severity,
                });
            }
        }

        // If no shard exceeds 2x average but there is a clear max, still flag it
        // when it accounts for more than 60% of total transfer
        if (bottleneck_list.items.len == 0 and shard_plans.len > 1 and
            max_transfer * 10 > total_transfer * 6)
        {
            try bottleneck_list.append(self.allocator, DataFlow.Bottleneck{
                .shard_id = max_shard_id,
                .operation = "data_transfer",
                .severity = @as(f64, @floatFromInt(max_transfer)) /
                    @as(f64, @floatFromInt(@max(1, avg_transfer))),
            });
        }

        return DataFlow{
            .total_transfer = total_transfer,
            .bottlenecks = try bottleneck_list.toOwnedSlice(self.allocator),
        };
    }

    /// Choose transfer optimization strategy based on data flow volume.
    fn optimizeDataTransfer(self: *DistributedQueryPlanner, data_flow: DataFlow) !TransferOptimization {
        _ = self;
        // Enable compression for transfers above 512KB
        const use_compression = data_flow.total_transfer > 512 * 1024;
        // Enable batching for transfers above 4MB
        const use_batching = data_flow.total_transfer > 4 * 1024 * 1024;
        // Scale buffer size with transfer volume (64KB to 1MB)
        const buffer_size: usize = if (data_flow.total_transfer > 10 * 1024 * 1024)
            1024 * 1024 // 1MB for large transfers
        else
            64 * 1024; // 64KB default

        return TransferOptimization{
            .compression = use_compression,
            .batching = use_batching,
            .buffer_size = buffer_size,
        };
    }

    /// Plan execution phases for distributed query execution.
    /// Phase 1: Parallel shard execution (send queries to all participating shards)
    /// Phase 2: Data transfer (collect results from shards to coordinator)
    /// Phase 3: Coordinator merge (joins, aggregations, sorts on collected data)
    /// Each phase has estimated duration based on the coordinator plan and transfer optimization.
    // CANARY: REQ=REQ-DIST-PLAN-011; FEATURE="ExecutionPhases"; ASPECT=PhasePlanning; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-10
    pub fn planExecutionPhases(self: *DistributedQueryPlanner, plan: CoordinatorPlan, optimization: TransferOptimization) ![]ExecutionPhase {
        var phases = std.ArrayList(ExecutionPhase).initCapacity(self.allocator, 3) catch return error.OutOfMemory;

        const shard_plans = plan.shard_plans;

        // Phase 1: Parallel shard execution
        // Each participating shard executes its local plan in parallel
        {
            var ops = std.ArrayList(ExecutionPhase.PhaseOperation).initCapacity(self.allocator, 4) catch return error.OutOfMemory;
            for (shard_plans) |sp| {
                try ops.append(self.allocator, ExecutionPhase.PhaseOperation{
                    .shard_id = sp.shard_id,
                    .operation_type = .local_scan,
                    .parameters = "",
                });
                // If the shard plan includes a filter, add it
                for (sp.local_plan.operations) |op| {
                    if (op == .filter) {
                        try ops.append(self.allocator, ExecutionPhase.PhaseOperation{
                            .shard_id = sp.shard_id,
                            .operation_type = .local_filter,
                            .parameters = "",
                        });
                        break;
                    }
                }
            }

            // Estimate duration: max shard cost (parallel execution = slowest shard)
            var max_shard_cost: f64 = 0;
            for (shard_plans) |sp| {
                if (sp.local_plan.estimated_cost > max_shard_cost) {
                    max_shard_cost = sp.local_plan.estimated_cost;
                }
            }
            // Convert cost units to estimated ms (1 cost unit ~ 0.1ms)
            const phase1_duration = @max(1.0, max_shard_cost * 0.1);

            try phases.append(self.allocator, ExecutionPhase{
                .phase_id = 1,
                .operations = try ops.toOwnedSlice(self.allocator),
                .dependencies = &.{}, // No dependencies; this is the first phase
                .estimated_duration = phase1_duration,
            });
        }

        // Phase 2: Data transfer (collect results from shards)
        {
            var ops = std.ArrayList(ExecutionPhase.PhaseOperation).initCapacity(self.allocator, 4) catch return error.OutOfMemory;
            for (shard_plans) |sp| {
                try ops.append(self.allocator, ExecutionPhase.PhaseOperation{
                    .shard_id = sp.shard_id,
                    .operation_type = .data_transfer,
                    .parameters = "",
                });
            }

            // Transfer duration depends on compression and total data volume
            const base_transfer_ms: f64 = if (optimization.compression) 5.0 else 10.0;
            // Scale with number of shards (parallel transfers, but coordinator receives serially)
            const shard_count: f64 = @floatFromInt(@max(1, shard_plans.len));
            const phase2_duration = base_transfer_ms * @log2(shard_count + 1.0);

            const phase1_dep: []const u32 = try self.allocator.alloc(u32, 1);
            @constCast(phase1_dep)[0] = 1;

            try phases.append(self.allocator, ExecutionPhase{
                .phase_id = 2,
                .operations = try ops.toOwnedSlice(self.allocator),
                .dependencies = phase1_dep,
                .estimated_duration = phase2_duration,
            });
        }

        // Phase 3: Coordinator merge (joins, aggregations, sorts)
        {
            var ops = std.ArrayList(ExecutionPhase.PhaseOperation).initCapacity(self.allocator, 4) catch return error.OutOfMemory;

            // Add coordinator operations based on the selected strategies
            if (plan.join_strategy != .none) {
                try ops.append(self.allocator, ExecutionPhase.PhaseOperation{
                    .shard_id = 0, // coordinator
                    .operation_type = .coordinator_join,
                    .parameters = "",
                });
            }
            if (plan.aggregation_strategy != .none) {
                try ops.append(self.allocator, ExecutionPhase.PhaseOperation{
                    .shard_id = 0,
                    .operation_type = .coordinator_aggregate,
                    .parameters = "",
                });
            }

            // Always add result merge (even without explicit strategies, results must be merged)
            try ops.append(self.allocator, ExecutionPhase.PhaseOperation{
                .shard_id = 0,
                .operation_type = .result_merge,
                .parameters = "",
            });

            // Merge duration depends on batching and coordinator strategies
            var merge_duration: f64 = if (optimization.batching) 3.0 else 8.0;
            if (plan.join_strategy != .none) merge_duration += 15.0;
            if (plan.aggregation_strategy != .none) merge_duration += 8.0;
            if (plan.sort_strategy != .none) merge_duration += 10.0;

            const phase2_dep: []const u32 = try self.allocator.alloc(u32, 1);
            @constCast(phase2_dep)[0] = 2;

            try phases.append(self.allocator, ExecutionPhase{
                .phase_id = 3,
                .operations = try ops.toOwnedSlice(self.allocator),
                .dependencies = phase2_dep,
                .estimated_duration = merge_duration,
            });
        }

        return phases.toOwnedSlice(self.allocator);
    }
};

// Federation manager for distributed system coordination
pub const FederationManager = struct {
    allocator: std.mem.Allocator,
    shards: std.ArrayList(ShardInfo),
    coordinator_id: u32,

    pub fn init(allocator: std.mem.Allocator) FederationManager {
        return .{
            .allocator = allocator,
            .shards = std.ArrayList(ShardInfo).initCapacity(allocator, 0) catch return FederationManager{ .allocator = allocator, .shards = undefined, .coordinator_id = 0 },
            .coordinator_id = 0,
        };
    }

    pub fn deinit(self: *FederationManager) void {
        self.shards.deinit(self.allocator);
    }

    pub fn registerShard(self: *FederationManager, shard_info: ShardInfo) !void {
        try self.shards.append(self.allocator, shard_info);
    }

    pub fn getShardByLabel(self: *FederationManager, label: []const u8) ?ShardInfo {
        for (self.shards.items) |shard| {
            for (shard.labels) |shard_label| {
                if (std.mem.eql(u8, label, shard_label)) {
                    return shard;
                }
            }
        }
        return null;
    }
};

// Data structures for distributed query planning
pub const DistributionAnalysis = struct {
    allocator: std.mem.Allocator,
    target_shards: std.ArrayList(u32),
    label_affinities: std.StringHashMap(u32),
    property_filters: std.ArrayList(PropertyFilter),
    cross_shard_joins: std.ArrayList(CrossShardJoin),
    /// Edge/relationship type labels for cross-shard join detection and routing
    edge_type_affinities: std.StringHashMap(u32),
    /// Function names encountered in WHERE clause for hash/geographic shard routing
    function_filters: std.ArrayList(FunctionFilter),

    pub fn init(allocator: std.mem.Allocator) DistributionAnalysis {
        return .{
            .allocator = allocator,
            .target_shards = std.ArrayList(u32).initCapacity(allocator, 0) catch std.ArrayList(u32){},
            .label_affinities = std.StringHashMap(u32).init(allocator),
            .property_filters = std.ArrayList(PropertyFilter).initCapacity(allocator, 0) catch std.ArrayList(PropertyFilter){},
            .cross_shard_joins = std.ArrayList(CrossShardJoin).initCapacity(allocator, 0) catch std.ArrayList(CrossShardJoin){},
            .edge_type_affinities = std.StringHashMap(u32).init(allocator),
            .function_filters = std.ArrayList(FunctionFilter).initCapacity(allocator, 0) catch std.ArrayList(FunctionFilter){},
        };
    }

    pub fn deinit(self: *DistributionAnalysis) void {
        self.target_shards.deinit(self.allocator);
        self.label_affinities.deinit();
        self.property_filters.deinit(self.allocator);
        self.cross_shard_joins.deinit(self.allocator);
        self.edge_type_affinities.deinit();
        self.function_filters.deinit(self.allocator);
    }

    pub fn addLabelAffinity(self: *DistributionAnalysis, label: []const u8) !void {
        try self.label_affinities.put(label, 1);
    }

    /// Track property-based filter conditions from node patterns in the MATCH clause.
    /// Stores property key and literal value for shard-routing decisions.
    /// Enables property-based shard pruning (e.g., if shard_key = property value).
    // CANARY: REQ=REQ-DIST-PLAN-012; FEATURE="PropertyFilterTracking"; ASPECT=ShardRouting; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-10
    pub fn addPropertyFilters(self: *DistributionAnalysis, properties: []const ast.Property) !void {
        for (properties) |prop| {
            // Extract literal value from the property expression for shard routing
            const value_str = extractLiteralValue(prop.value);
            try self.property_filters.append(self.allocator, PropertyFilter{
                .property = prop.key,
                .operator = .eq, // Pattern properties imply equality matching
                .value = value_str,
            });
        }
    }

    /// Track relationship type patterns for cross-shard join detection and routing.
    /// Stores edge type labels so the shard pruner can route queries involving
    /// specific relationship types to shards that host those edges.
    // CANARY: REQ=REQ-DIST-PLAN-013; FEATURE="EdgePatternTracking"; ASPECT=ShardRouting; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-10
    pub fn addEdgePattern(self: *DistributionAnalysis, rel: ast.RelPattern) !void {
        for (rel.types) |edge_type| {
            // Track the edge type as an affinity (count occurrences)
            const existing = self.edge_type_affinities.get(edge_type);
            try self.edge_type_affinities.put(edge_type, (existing orelse 0) + 1);
        }
    }

    /// Process binary comparison expressions from WHERE clause for shard filtering.
    /// Extracts property name from LHS (PropertyAccess or Ident) and literal value
    /// from RHS, storing as property filters for shard selection.
    // CANARY: REQ=REQ-DIST-PLAN-014; FEATURE="FilterConditionExtraction"; ASPECT=ShardRouting; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-10
    pub fn addFilterCondition(self: *DistributionAnalysis, bin: struct { op: ast.BinOp, left: *ast.Expr, right: *ast.Expr }) !void {
        // Extract property name from LHS
        const prop_name: ?[]const u8 = switch (bin.left.*) {
            .PropertyAccess => |pa| pa.property,
            .Ident => |ident| ident.cnf,
            else => null,
        };

        if (prop_name) |name| {
            // Extract literal value from RHS
            const value_str = extractLiteralValue(bin.right);
            const filter_op: PropertyFilter.FilterOperator = switch (bin.op) {
                .Eq => .eq,
                .Ne => .ne,
                .Lt => .lt,
                .Le => .le,
                .Gt => .gt,
                .Ge => .ge,
                else => .eq,
            };
            try self.property_filters.append(self.allocator, PropertyFilter{
                .property = name,
                .operator = filter_op,
                .value = value_str,
            });
        }
    }

    /// Process function calls (e.g., geographic hash functions) for shard routing.
    /// Extracts function name and argument count, storing for hash-based or
    /// geographic shard selection strategies.
    // CANARY: REQ=REQ-DIST-PLAN-015; FEATURE="FunctionFilterExtraction"; ASPECT=ShardRouting; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-10
    pub fn addFunctionFilter(self: *DistributionAnalysis, call: struct { callee: *ast.Expr, args: []*ast.Expr }) !void {
        // Extract function name from callee
        const func_name: ?[]const u8 = switch (call.callee.*) {
            .Ident => |ident| ident.cnf,
            else => null,
        };

        if (func_name) |name| {
            try self.function_filters.append(self.allocator, FunctionFilter{
                .function_name = name,
                .arg_count = call.args.len,
            });
        }
    }

    /// Extract a string representation of a literal Expr value for filter storage.
    /// Returns the raw literal text for strings/idents, or a fixed placeholder
    /// for non-literal expressions.
    fn extractLiteralValue(expr: *const ast.Expr) []const u8 {
        return switch (expr.*) {
            .String => |s| s,
            .Ident => |ident| ident.orig,
            .Int => "<<int>>",
            .Bool => "<<bool>>",
            .Null => "<<null>>",
            else => "<<expr>>",
        };
    }
};

pub const ShardPlan = struct {
    shard_id: u32,
    query: ast.Query,
    local_plan: ShardLocalPlan,
    estimated_rows: usize,
    estimated_cost: f64,
    data_transfer_size: usize,
};

pub const ShardLocalPlan = struct {
    operations: []const Operation,
    estimated_cost: f64,

    pub const Operation = enum {
        scan,
        filter,
        project,
        join,
        aggregate,
        sort,
    };
};

pub const CoordinatorPlan = struct {
    allocator: std.mem.Allocator,
    target_shards: std.ArrayList(u32),
    join_strategy: JoinStrategy = .none,
    aggregation_strategy: AggregationStrategy = .none,
    sort_strategy: SortStrategy = .none,
    union_strategy: UnionStrategy = .none,
    /// Shard plans for data flow analysis and execution phase planning
    shard_plans: []const ShardPlan = &.{},

    pub fn init(allocator: std.mem.Allocator) CoordinatorPlan {
        return .{
            .allocator = allocator,
            .target_shards = std.ArrayList(u32).initCapacity(allocator, 0) catch std.ArrayList(u32){},
        };
    }

    pub fn deinit(self: *CoordinatorPlan) void {
        self.target_shards.deinit(self.allocator);
    }
};

pub const DistributedPlan = struct {
    coordinator_plan: CoordinatorPlan,
    data_flow: DataFlow,
    transfer_optimization: TransferOptimization,
    execution_phases: []ExecutionPhase,
    estimated_cost: f64,
    parallelism_level: u8,
};

// Strategy enums for different distributed operations
pub const JoinStrategy = enum {
    none,
    hash_join,
    merge_join,
    broadcast_join,
    shuffle_join,
};

pub const AggregationStrategy = enum {
    none,
    single_phase,
    two_phase,
    streaming,
};

pub const SortStrategy = enum {
    none,
    merge_sort,
    distributed_sort,
    top_k,
};

pub const UnionStrategy = enum {
    none,
    streaming_merge,
    batch_merge,
    parallel_union,
};

// Supporting data structures
pub const ShardRegistry = struct {
    allocator: std.mem.Allocator,
    shards: std.AutoHashMap(u32, ShardInfo),

    pub fn init(allocator: std.mem.Allocator) ShardRegistry {
        return .{
            .allocator = allocator,
            .shards = std.AutoHashMap(u32, ShardInfo).init(allocator),
        };
    }

    pub fn deinit(self: *ShardRegistry) void {
        self.shards.deinit();
    }
};

pub const ShardInfo = struct {
    id: u32,
    endpoint: []const u8,
    labels: []const []const u8,
    estimated_size: usize,
    status: ShardStatus,

    pub const ShardStatus = enum {
        active,
        degraded,
        offline,
    };
};

pub const DistributedCostModel = struct {
    network_latency: f64,
    bandwidth: f64,
    cpu_factor: f64,
    memory_factor: f64,

    pub fn init() DistributedCostModel {
        return .{
            .network_latency = 5.0, // 5ms average
            .bandwidth = 1000.0, // 1Gbps
            .cpu_factor = 1.0,
            .memory_factor = 0.1,
        };
    }

    /// Estimate shard execution cost factoring in CPU and memory overhead.
    pub fn estimateShardCost(self: *DistributedCostModel, plan: ShardLocalPlan) f64 {
        // Base cost from the local plan, scaled by CPU and memory factors
        return plan.estimated_cost * self.cpu_factor + @as(f64, @floatFromInt(plan.operations.len)) * self.memory_factor;
    }

    /// Estimate total distributed execution cost from coordinator plan and transfer settings.
    pub fn estimateTotalCost(self: *DistributedCostModel, plan: CoordinatorPlan, optimization: TransferOptimization) f64 {
        const shard_count: f64 = @floatFromInt(@max(1, plan.target_shards.items.len));

        // Network cost: latency per shard + bandwidth factor
        var network_cost = shard_count * self.network_latency;
        if (optimization.compression) {
            network_cost *= 0.6; // compression reduces transfer cost ~40%
        }

        // Coordination overhead: joins and aggregations add cost
        var coord_cost: f64 = 0;
        if (plan.join_strategy != .none) coord_cost += 50.0 * self.cpu_factor;
        if (plan.aggregation_strategy != .none) coord_cost += 20.0 * self.cpu_factor;
        if (plan.sort_strategy != .none) coord_cost += 30.0 * self.cpu_factor;
        if (plan.union_strategy != .none) coord_cost += 10.0 * self.cpu_factor;

        return network_cost + coord_cost;
    }
};

pub const DataFlow = struct {
    total_transfer: usize,
    bottlenecks: []const Bottleneck,

    pub const Bottleneck = struct {
        shard_id: u32,
        operation: []const u8,
        severity: f64,
    };
};

pub const TransferOptimization = struct {
    compression: bool,
    batching: bool,
    streaming: bool = true,
    buffer_size: usize = 64 * 1024, // 64KB default
};

pub const ExecutionPhase = struct {
    phase_id: u32,
    operations: []const PhaseOperation,
    dependencies: []const u32,
    estimated_duration: f64,

    pub const PhaseOperation = struct {
        shard_id: u32,
        operation_type: OperationType,
        parameters: []const u8,

        pub const OperationType = enum {
            local_scan,
            local_filter,
            data_transfer,
            coordinator_join,
            coordinator_aggregate,
            result_merge,
        };
    };
};

pub const PropertyFilter = struct {
    property: []const u8,
    operator: FilterOperator,
    value: []const u8,

    pub const FilterOperator = enum {
        eq,
        ne,
        lt,
        le,
        gt,
        ge,
        in,
        contains,
    };
};

pub const CrossShardJoin = struct {
    left_shard: u32,
    right_shard: u32,
    join_key: []const u8,
    estimated_cardinality: usize,
};

/// Filter entry for function calls in WHERE clauses that may influence shard routing
/// (e.g., geographic hash functions, partition functions).
pub const FunctionFilter = struct {
    function_name: []const u8,
    arg_count: usize,
};

// --- Tests ---

test "estimateShardRows: returns default 1000 without stats" {
    const ally = std.testing.allocator;
    var fm = FederationManager.init(ally);
    defer fm.deinit();
    var planner = DistributedQueryPlanner.init(ally, &fm);
    defer planner.deinit();

    var analysis = DistributionAnalysis.init(ally);
    defer analysis.deinit();

    const estimate = planner.estimateShardRows(1, analysis);
    try std.testing.expectEqual(@as(usize, 1000), estimate);
}

test "estimateShardRows: uses CBO stats when registry is set" {
    const ally = std.testing.allocator;
    var fm = FederationManager.init(ally);
    defer fm.deinit();
    var planner = DistributedQueryPlanner.init(ally, &fm);
    defer planner.deinit();

    // Set up stats registry with known data
    var registry = cbo.StatsRegistry.init(ally);
    defer registry.deinit();
    try registry.updateTableStats("Person", .{
        .row_count = 10000,
        .page_count = 500,
        .avg_row_size = 128,
        .last_updated = 0,
    });

    planner.setStatsRegistry(&registry);

    // Register 2 shards in the shard registry so rows distribute
    try planner.shard_registry.shards.put(1, ShardInfo{
        .id = 1,
        .endpoint = "localhost:3141",
        .labels = &.{},
        .estimated_size = 0,
        .status = .active,
    });
    try planner.shard_registry.shards.put(2, ShardInfo{
        .id = 2,
        .endpoint = "localhost:3142",
        .labels = &.{},
        .estimated_size = 0,
        .status = .active,
    });

    // Create analysis with label affinity matching our stats
    var analysis = DistributionAnalysis.init(ally);
    defer analysis.deinit();
    try analysis.addLabelAffinity("Person");

    const estimate = planner.estimateShardRows(1, analysis);
    // 10000 / 2 shards = 5000 + 10% buffer = 5500
    try std.testing.expectEqual(@as(usize, 5500), estimate);
}

test "estimateShardRows: falls back to default when label has no stats" {
    const ally = std.testing.allocator;
    var fm = FederationManager.init(ally);
    defer fm.deinit();
    var planner = DistributedQueryPlanner.init(ally, &fm);
    defer planner.deinit();

    var registry = cbo.StatsRegistry.init(ally);
    defer registry.deinit();
    // Registry is empty - no stats for any label

    planner.setStatsRegistry(&registry);

    var analysis = DistributionAnalysis.init(ally);
    defer analysis.deinit();
    try analysis.addLabelAffinity("UnknownLabel");

    const estimate = planner.estimateShardRows(1, analysis);
    try std.testing.expectEqual(@as(usize, 1000), estimate);
}

test "selectParticipatingShards: returns defaults when registry is empty" {
    const ally = std.testing.allocator;
    var fm = FederationManager.init(ally);
    defer fm.deinit();
    var planner = DistributedQueryPlanner.init(ally, &fm);
    defer planner.deinit();

    var analysis = DistributionAnalysis.init(ally);
    defer analysis.deinit();

    const shards = try planner.selectParticipatingShards(analysis);
    defer ally.free(shards);

    try std.testing.expectEqual(@as(usize, 2), shards.len);
    // Default shard IDs: 1, 2
    try std.testing.expectEqual(@as(u32, 1), shards[0]);
    try std.testing.expectEqual(@as(u32, 2), shards[1]);
}

test "selectParticipatingShards: prunes by label affinity" {
    const ally = std.testing.allocator;
    var fm = FederationManager.init(ally);
    defer fm.deinit();
    var planner = DistributedQueryPlanner.init(ally, &fm);
    defer planner.deinit();

    // Register 3 shards: shard 1 has Person, shard 2 has Order, shard 3 has Person+Order
    const person_labels: []const []const u8 = &.{"Person"};
    const order_labels: []const []const u8 = &.{"Order"};
    const both_labels: []const []const u8 = &.{ "Person", "Order" };
    try planner.shard_registry.shards.put(1, ShardInfo{
        .id = 1,
        .endpoint = "localhost:3141",
        .labels = person_labels,
        .estimated_size = 0,
        .status = .active,
    });
    try planner.shard_registry.shards.put(2, ShardInfo{
        .id = 2,
        .endpoint = "localhost:3142",
        .labels = order_labels,
        .estimated_size = 0,
        .status = .active,
    });
    try planner.shard_registry.shards.put(3, ShardInfo{
        .id = 3,
        .endpoint = "localhost:3143",
        .labels = both_labels,
        .estimated_size = 0,
        .status = .active,
    });

    // Query only references Person label
    var analysis = DistributionAnalysis.init(ally);
    defer analysis.deinit();
    try analysis.addLabelAffinity("Person");

    const shards = try planner.selectParticipatingShards(analysis);
    defer ally.free(shards);

    // Should only include shards 1 and 3 (both have Person label)
    try std.testing.expectEqual(@as(usize, 2), shards.len);
    // Verify both returned shards have Person label
    for (shards) |sid| {
        const info = planner.shard_registry.shards.get(sid).?;
        var found = false;
        for (info.labels) |lbl| {
            if (std.mem.eql(u8, lbl, "Person")) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "selectParticipatingShards: returns all when no label match" {
    const ally = std.testing.allocator;
    var fm = FederationManager.init(ally);
    defer fm.deinit();
    var planner = DistributedQueryPlanner.init(ally, &fm);
    defer planner.deinit();

    const order_labels: []const []const u8 = &.{"Order"};
    try planner.shard_registry.shards.put(1, ShardInfo{
        .id = 1,
        .endpoint = "localhost:3141",
        .labels = order_labels,
        .estimated_size = 0,
        .status = .active,
    });
    try planner.shard_registry.shards.put(2, ShardInfo{
        .id = 2,
        .endpoint = "localhost:3142",
        .labels = order_labels,
        .estimated_size = 0,
        .status = .active,
    });

    // Query references a label that no shard advertises
    var analysis = DistributionAnalysis.init(ally);
    defer analysis.deinit();
    try analysis.addLabelAffinity("UnknownLabel");

    const shards = try planner.selectParticipatingShards(analysis);
    defer ally.free(shards);

    // Falls back to all shards since no match was found
    try std.testing.expectEqual(@as(usize, 2), shards.len);
}

// --- GAP-D007: Tests for wired-up stub methods ---

test "estimateShardRows: uses shard estimated_size as fallback" {
    const ally = std.testing.allocator;
    var fm = FederationManager.init(ally);
    defer fm.deinit();
    var planner = DistributedQueryPlanner.init(ally, &fm);
    defer planner.deinit();

    // Register a shard with estimated_size but no CBO stats
    try planner.shard_registry.shards.put(1, ShardInfo{
        .id = 1,
        .endpoint = "localhost:3141",
        .labels = &.{},
        .estimated_size = 5000,
        .status = .active,
    });

    var analysis = DistributionAnalysis.init(ally);
    defer analysis.deinit();
    // No label affinities, no CBO stats -> should use estimated_size

    const estimate = planner.estimateShardRows(1, analysis);
    // Should return estimated_size (5000) instead of hardcoded 1000
    try std.testing.expectEqual(@as(usize, 5000), estimate);
}

test "estimateShardRows: weights by shard size when CBO stats available" {
    const ally = std.testing.allocator;
    var fm = FederationManager.init(ally);
    defer fm.deinit();
    var planner = DistributedQueryPlanner.init(ally, &fm);
    defer planner.deinit();

    var registry = cbo.StatsRegistry.init(ally);
    defer registry.deinit();
    try registry.updateTableStats("Person", .{
        .row_count = 10000,
        .page_count = 500,
        .avg_row_size = 128,
        .last_updated = 0,
    });
    planner.setStatsRegistry(&registry);

    // Shard 1 has 3x the data of shard 2
    try planner.shard_registry.shards.put(1, ShardInfo{
        .id = 1,
        .endpoint = "localhost:3141",
        .labels = &.{},
        .estimated_size = 3000,
        .status = .active,
    });
    try planner.shard_registry.shards.put(2, ShardInfo{
        .id = 2,
        .endpoint = "localhost:3142",
        .labels = &.{},
        .estimated_size = 1000,
        .status = .active,
    });

    var analysis = DistributionAnalysis.init(ally);
    defer analysis.deinit();
    try analysis.addLabelAffinity("Person");

    const est1 = planner.estimateShardRows(1, analysis);
    const est2 = planner.estimateShardRows(2, analysis);

    // Shard 1 should get more rows than shard 2 (3/4 vs 1/4 of 10000)
    // Shard 1: 10000 * 3000/4000 = 7500 + 10% = 8250
    // Shard 2: 10000 * 1000/4000 = 2500 + 10% = 2750
    try std.testing.expectEqual(@as(usize, 8250), est1);
    try std.testing.expectEqual(@as(usize, 2750), est2);
}

test "optimizeShardLocalPlan: derives operations from query structure" {
    const ally = std.testing.allocator;
    var fm = FederationManager.init(ally);
    defer fm.deinit();
    var planner = DistributedQueryPlanner.init(ally, &fm);
    defer planner.deinit();

    // Build a minimal query with WHERE and ORDER BY
    var query = std.mem.zeroes(ast.Query);
    query.match = .{ .chains = &.{} };
    query.ret = .{ .items = &.{}, .distinct = false };
    // Set WHERE clause to trigger filter operation
    query.where_clause = .{ .Literal = .{ .Boolean = true } };
    // Set ORDER BY to trigger sort
    query.order_by = &ast.OrderBy{ .items = &.{} };

    const plan = try planner.optimizeShardLocalPlan(query, 1);
    defer ally.free(plan.operations);

    // Should have: scan, filter, sort, project = 4 operations
    try std.testing.expectEqual(@as(usize, 4), plan.operations.len);
    try std.testing.expectEqual(ShardLocalPlan.Operation.scan, plan.operations[0]);
    try std.testing.expectEqual(ShardLocalPlan.Operation.filter, plan.operations[1]);
    try std.testing.expectEqual(ShardLocalPlan.Operation.sort, plan.operations[2]);
    try std.testing.expectEqual(ShardLocalPlan.Operation.project, plan.operations[3]);

    // Cost should be > 0 (not hardcoded 100)
    try std.testing.expect(plan.estimated_cost > 0);
}

test "estimateDataTransfer: scales with plan cost" {
    const ally = std.testing.allocator;
    var fm = FederationManager.init(ally);
    defer fm.deinit();
    var planner = DistributedQueryPlanner.init(ally, &fm);
    defer planner.deinit();

    const small_plan = ShardLocalPlan{ .operations = &.{}, .estimated_cost = 10.0 };
    const large_plan = ShardLocalPlan{ .operations = &.{}, .estimated_cost = 1000.0 };

    const small_transfer = planner.estimateDataTransfer(small_plan);
    const large_transfer = planner.estimateDataTransfer(large_plan);

    // Large plan should transfer more data
    try std.testing.expect(large_transfer > small_transfer);
    // Minimum 1KB
    try std.testing.expect(small_transfer >= 1024);
}

test "estimateTotalCost: varies with coordinator strategies" {
    const ally = std.testing.allocator;

    var cost_model = DistributedCostModel.init();

    // Plan with no coordination needed
    var simple_plan = CoordinatorPlan.init(ally);
    defer simple_plan.deinit();
    const simple_cost = cost_model.estimateTotalCost(simple_plan, TransferOptimization{ .compression = false, .batching = false });

    // Plan with join + aggregation
    var complex_plan = CoordinatorPlan.init(ally);
    defer complex_plan.deinit();
    complex_plan.join_strategy = .hash_join;
    complex_plan.aggregation_strategy = .two_phase;
    const complex_cost = cost_model.estimateTotalCost(complex_plan, TransferOptimization{ .compression = false, .batching = false });

    // Complex plan should cost more
    try std.testing.expect(complex_cost > simple_cost);
}

test "estimateTotalCost: compression reduces cost" {
    const ally = std.testing.allocator;
    var cost_model = DistributedCostModel.init();

    var plan = CoordinatorPlan.init(ally);
    defer plan.deinit();
    try plan.target_shards.append(ally, 1);
    try plan.target_shards.append(ally, 2);

    const no_compress = cost_model.estimateTotalCost(plan, TransferOptimization{ .compression = false, .batching = false });
    const with_compress = cost_model.estimateTotalCost(plan, TransferOptimization{ .compression = true, .batching = false });

    try std.testing.expect(with_compress < no_compress);
}
