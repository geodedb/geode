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

        // Extract label affinities from MATCH pattern chains
        for (query.match.chains) |chain| {
            for (chain.nodes) |node| {
                for (node.labels) |label| {
                    try analysis.addLabelAffinity(label);
                }
            }
        }

        return analysis;
    }

    // Generate optimized plans for each participating shard
    fn generateShardPlans(self: *DistributedQueryPlanner, query: *const ast.Query, analysis: DistributionAnalysis) ![]ShardPlan {
        var shard_plans = std.ArrayList(ShardPlan).initCapacity(self.allocator, 4) catch return error.OutOfMemory;

        // Simplified shard planning for compilation
        const shard_ids = [_]u32{ 1, 2 }; // Mock shard IDs
        for (shard_ids) |shard_id| {
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

    // Plan coordinator operations for distributed execution
    fn planCoordinatorOperations(self: *DistributedQueryPlanner, query: *const ast.Query, shard_plans: []const ShardPlan) !CoordinatorPlan {
        var coordinator_plan = CoordinatorPlan.init(self.allocator);

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

    // Analyze MATCH chain for shard affinity patterns
    fn analyzeMatchChain(self: *DistributedQueryPlanner, analysis: *DistributionAnalysis, chain: []const u8) !void {
        _ = self;
        _ = analysis;
        _ = chain;
        // Simplified implementation - would analyze actual MATCH patterns
        // for shard affinity in a real implementation
    }

    // Analyze WHERE clause for shard-specific filtering
    fn analyzeWhereClause(self: *DistributedQueryPlanner, analysis: *DistributionAnalysis, where: ast.Expression) !void {
        _ = self;

        switch (where) {
            .BinaryOp => |binop| {
                // Analyze comparison operations for shard filtering
                if (binop.op == .Eq or binop.op == .In) {
                    try analysis.addFilterCondition(binop);
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
        _ = query;
        // Check if query involves UNION across shards
        return false; // Simplified for now
    }

    /// Estimate row count for a shard using CBO statistics when available.
    /// Falls back to a default heuristic (1000 rows) when no stats exist.
    fn estimateShardRows(self: *DistributedQueryPlanner, shard_id: u32, analysis: DistributionAnalysis) usize {
        _ = shard_id;

        // Try CBO statistics for each label that has shard affinity
        if (self.stats_registry) |registry| {
            var it = analysis.label_affinities.iterator();
            while (it.next()) |entry| {
                if (registry.getTableStats(entry.key_ptr.*)) |stats| {
                    const total_shards = @max(1, self.shard_registry.shards.count());
                    const rows_per_shard = stats.row_count / total_shards;
                    // Add 10% buffer for estimation variance
                    return rows_per_shard + rows_per_shard / 10;
                }
            }
        }

        return 1000; // Default when no statistics available
    }

    fn estimateDataTransfer(self: *DistributedQueryPlanner, plan: ShardLocalPlan) usize {
        _ = self;
        _ = plan;
        return 1024 * 1024; // 1MB estimated transfer
    }

    fn determineOptimalParallelism(self: *DistributedQueryPlanner, plan: CoordinatorPlan) u8 {
        _ = self;
        // Determine optimal parallelism based on shard count and operation complexity
        const shard_count = plan.target_shards.items.len;
        return @min(@as(u8, @intCast(shard_count)), 8); // Max 8 parallel operations
    }

    // Placeholder methods for complex distributed operations
    fn generateShardQuery(self: *DistributedQueryPlanner, query: *const ast.Query, shard_id: u32, analysis: DistributionAnalysis) !ast.Query {
        _ = self;
        _ = shard_id;
        _ = analysis;
        return query.*; // Simplified - would modify query for shard-specific execution
    }

    fn optimizeShardLocalPlan(self: *DistributedQueryPlanner, query: ast.Query, shard_id: u32) !ShardLocalPlan {
        _ = self;
        _ = query;
        _ = shard_id;
        return ShardLocalPlan{ .operations = &.{}, .estimated_cost = 100.0 };
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

    fn planDistributedJoin(self: *DistributedQueryPlanner, query: *const ast.Query, shard_plans: []const ShardPlan) !JoinStrategy {
        _ = self;
        _ = query;
        _ = shard_plans;
        return .hash_join; // Simplified
    }

    fn planDistributedAggregation(self: *DistributedQueryPlanner, query: *const ast.Query, shard_plans: []const ShardPlan) !AggregationStrategy {
        _ = self;
        _ = query;
        _ = shard_plans;
        return .two_phase; // Simplified
    }

    fn planDistributedSort(self: *DistributedQueryPlanner, order: ast.OrderBy, shard_plans: []const ShardPlan) !SortStrategy {
        _ = self;
        _ = order;
        _ = shard_plans;
        return .merge_sort; // Simplified
    }

    fn planDistributedUnion(self: *DistributedQueryPlanner, query: *const ast.Query, shard_plans: []const ShardPlan) !UnionStrategy {
        _ = self;
        _ = query;
        _ = shard_plans;
        return .streaming_merge; // Simplified
    }

    fn analyzeDataFlow(self: *DistributedQueryPlanner, plan: CoordinatorPlan) !DataFlow {
        _ = self;
        _ = plan;
        return DataFlow{ .total_transfer = 0, .bottlenecks = &.{} };
    }

    fn optimizeDataTransfer(self: *DistributedQueryPlanner, data_flow: DataFlow) !TransferOptimization {
        _ = self;
        _ = data_flow;
        return TransferOptimization{ .compression = true, .batching = true };
    }

    fn planExecutionPhases(self: *DistributedQueryPlanner, plan: CoordinatorPlan, optimization: TransferOptimization) ![]ExecutionPhase {
        _ = self;
        _ = plan;
        _ = optimization;
        return &.{};
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

    pub fn init(allocator: std.mem.Allocator) DistributionAnalysis {
        return .{
            .allocator = allocator,
            .target_shards = std.ArrayList(u32).initCapacity(allocator, 0) catch std.ArrayList(u32){},
            .label_affinities = std.StringHashMap(u32).init(allocator),
            .property_filters = std.ArrayList(PropertyFilter).initCapacity(allocator, 0) catch std.ArrayList(PropertyFilter){},
            .cross_shard_joins = std.ArrayList(CrossShardJoin).initCapacity(allocator, 0) catch std.ArrayList(CrossShardJoin){},
        };
    }

    pub fn deinit(self: *DistributionAnalysis) void {
        self.target_shards.deinit(self.allocator);
        self.label_affinities.deinit();
        self.property_filters.deinit(self.allocator);
        self.cross_shard_joins.deinit(self.allocator);
    }

    pub fn addLabelAffinity(self: *DistributionAnalysis, label: []const u8) !void {
        try self.label_affinities.put(label, 1);
    }

    pub fn addPropertyFilters(self: *DistributionAnalysis, properties: []const ast.Property) !void {
        _ = self;
        _ = properties;
        // Simplified implementation
    }

    pub fn addEdgePattern(self: *DistributionAnalysis, edge: ast.EdgePattern) !void {
        _ = self;
        _ = edge;
        // Simplified implementation
    }

    pub fn addFilterCondition(self: *DistributionAnalysis, binop: ast.BinaryOp) !void {
        _ = self;
        _ = binop;
        // Simplified implementation
    }

    pub fn addFunctionFilter(self: *DistributionAnalysis, call: ast.CallExpression) !void {
        _ = self;
        _ = call;
        // Simplified implementation
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

    pub fn estimateShardCost(self: *DistributedCostModel, plan: ShardLocalPlan) f64 {
        _ = self;
        return plan.estimated_cost;
    }

    pub fn estimateTotalCost(self: *DistributedCostModel, plan: CoordinatorPlan, optimization: TransferOptimization) f64 {
        _ = self;
        _ = plan;
        _ = optimization;
        return 500.0; // Simplified total cost estimation
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
