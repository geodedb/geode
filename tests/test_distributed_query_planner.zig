const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const qp = geode.distributed.query_planner;
const cbo = geode.cbo_api_stub;

// CANARY: REQ=REQ-DISTRIBUTED-QUERY-PLANNER-001; FEATURE="Distributed Query Planning"; ASPECT=BasicPlanGeneration; STATUS=TESTED; TEST=TestCANARY_REQ_DISTRIBUTED_QUERY_PLANNER_001_BasicPlanGeneration; OWNER=distributed; UPDATED=2026-04-05
// CANARY: REQ=REQ-DISTRIBUTED-QUERY-PLANNER-002; FEATURE="Distributed Query Planning"; ASPECT=FederationIntegration; STATUS=TESTED; TEST=TestCANARY_REQ_DISTRIBUTED_QUERY_PLANNER_002_FederationIntegration; OWNER=distributed; UPDATED=2026-04-05
// CANARY: REQ=REQ-DISTRIBUTED-QUERY-PLANNER-003; FEATURE="Distributed Query Planning"; ASPECT=CostOptimization; STATUS=TESTED; TEST=TestCANARY_REQ_DISTRIBUTED_QUERY_PLANNER_003_CostOptimization; OWNER=distributed; UPDATED=2026-04-05

// Pull in the embedded tests from query_planner.zig itself
comptime {
    _ = qp;
}

test "TestCANARY_REQ_DISTRIBUTED_QUERY_PLANNER_001_BasicPlanGeneration" {
    // Test that the planner initializes and produces valid estimates
    const allocator = testing.allocator;

    var federation_manager = qp.FederationManager.init(allocator);
    defer federation_manager.deinit();

    var planner = qp.DistributedQueryPlanner.init(allocator, &federation_manager);
    defer planner.deinit();

    // Verify default shard estimation without CBO stats returns 1000
    var analysis = qp.DistributionAnalysis.init(allocator);
    defer analysis.deinit();

    const estimate = planner.estimateShardRows(1, analysis);
    try testing.expectEqual(@as(usize, 1000), estimate);

    // Verify parallelism determination works
    var coord_plan = qp.CoordinatorPlan.init(allocator);
    defer coord_plan.deinit();
    const parallelism = planner.determineOptimalParallelism(coord_plan);
    try testing.expect(parallelism <= 8);
}

test "TestCANARY_REQ_DISTRIBUTED_QUERY_PLANNER_002_FederationIntegration" {
    // Test federation manager integration with distributed planner
    const allocator = testing.allocator;

    var federation_manager = qp.FederationManager.init(allocator);
    defer federation_manager.deinit();

    // Test shard registry functionality
    var planner = qp.DistributedQueryPlanner.init(allocator, &federation_manager);
    defer planner.deinit();

    // Verify shard registry is initialized
    try testing.expect(planner.shard_registry.shards.count() == 0); // Empty initially

    // Test cost model initialization
    const cost_model = planner.cost_model;
    try testing.expect(cost_model.network_latency > 0);
    try testing.expect(cost_model.bandwidth > 0);
    try testing.expect(cost_model.cpu_factor >= 0);
    try testing.expect(cost_model.memory_factor >= 0);

    // Test default cost model parameters
    try testing.expectEqual(@as(f64, 5.0), cost_model.network_latency);
    try testing.expectEqual(@as(f64, 1000.0), cost_model.bandwidth);
    try testing.expectEqual(@as(f64, 1.0), cost_model.cpu_factor);
    try testing.expectEqual(@as(f64, 0.1), cost_model.memory_factor);

    // Test that CBO registry integration works
    var registry = cbo.StatsRegistry.init(allocator);
    defer registry.deinit();
    try registry.updateTableStats("Person", .{
        .row_count = 10000,
        .page_count = 500,
        .avg_row_size = 128,
        .last_updated = 0,
    });
    planner.setStatsRegistry(&registry);
    try testing.expect(planner.stats_registry != null);
}

test "TestCANARY_REQ_DISTRIBUTED_QUERY_PLANNER_003_CostOptimization" {
    // Test distributed cost optimization strategies
    const allocator = testing.allocator;

    var federation_manager = qp.FederationManager.init(allocator);
    defer federation_manager.deinit();

    var planner = qp.DistributedQueryPlanner.init(allocator, &federation_manager);
    defer planner.deinit();

    // Test cost estimation for different plan sizes.
    // estimateShardCost = plan.estimated_cost * cpu_factor + ops.len * memory_factor
    // With cpu_factor=1.0, memory_factor=0.1:
    //   50.0 cost, 0 ops -> 50.0 * 1.0 + 0 * 0.1 = 50.0
    //   250.0 cost, 0 ops -> 250.0
    //   500.0 cost, 0 ops -> 500.0
    const cost_scenarios = [_]struct {
        operation_count: u32,
        expected_cost: f64,
    }{
        .{ .operation_count = 1, .expected_cost = 50.0 },
        .{ .operation_count = 5, .expected_cost = 250.0 },
        .{ .operation_count = 10, .expected_cost = 500.0 },
    };

    for (cost_scenarios) |scenario| {
        const mock_plan = qp.ShardLocalPlan{
            .operations = &.{},
            .estimated_cost = @as(f64, @floatFromInt(scenario.operation_count)) * 50.0,
        };

        const estimated_cost = planner.cost_model.estimateShardCost(mock_plan);

        // Cost should equal plan.estimated_cost * cpu_factor (1.0) for empty operations
        try testing.expectEqual(scenario.expected_cost, estimated_cost);
        try testing.expect(!std.math.isNan(estimated_cost));
        try testing.expect(!std.math.isInf(estimated_cost));
    }
}

test "Distributed query plan data structures" {
    // Test the various data structures used in distributed planning
    const allocator = testing.allocator;

    // Test ShardRegistry
    var shard_registry = qp.ShardRegistry.init(allocator);
    defer shard_registry.deinit();

    // Test initial state
    try testing.expect(shard_registry.shards.count() == 0);

    // Test DistributedCostModel
    const cost_model = qp.DistributedCostModel.init();

    // Verify default parameters
    try testing.expect(cost_model.network_latency == 5.0);
    try testing.expect(cost_model.bandwidth == 1000.0);
    try testing.expect(cost_model.cpu_factor == 1.0);
    try testing.expect(cost_model.memory_factor == 0.1);

    // Test TransferOptimization defaults
    const transfer_opt = qp.TransferOptimization{
        .compression = true,
        .batching = true,
    };

    try testing.expect(transfer_opt.compression == true);
    try testing.expect(transfer_opt.batching == true);
    try testing.expect(transfer_opt.streaming == true); // Default
    try testing.expect(transfer_opt.buffer_size == 64 * 1024); // 64KB default
}

test "Distributed strategy enums completeness" {
    // Test that all strategy enums have valid values

    // Test JoinStrategy enum
    const join_strategies = [_]qp.JoinStrategy{ .none, .hash_join, .merge_join, .broadcast_join, .shuffle_join };

    for (join_strategies) |strategy| {
        switch (strategy) {
            .none, .hash_join, .merge_join, .broadcast_join, .shuffle_join => {},
        }
    }

    // Test AggregationStrategy enum
    const agg_strategies = [_]qp.AggregationStrategy{ .none, .single_phase, .two_phase, .streaming };

    for (agg_strategies) |strategy| {
        switch (strategy) {
            .none, .single_phase, .two_phase, .streaming => {},
        }
    }

    // Test SortStrategy enum
    const sort_strategies = [_]qp.SortStrategy{ .none, .merge_sort, .distributed_sort, .top_k };

    for (sort_strategies) |strategy| {
        switch (strategy) {
            .none, .merge_sort, .distributed_sort, .top_k => {},
        }
    }

    // Test UnionStrategy enum
    const union_strategies = [_]qp.UnionStrategy{ .none, .streaming_merge, .batch_merge, .parallel_union };

    for (union_strategies) |strategy| {
        switch (strategy) {
            .none, .streaming_merge, .batch_merge, .parallel_union => {},
        }
    }
}

test "Federation manager shard management" {
    // Test federation manager's shard management capabilities
    const allocator = testing.allocator;

    var federation_manager = qp.FederationManager.init(allocator);
    defer federation_manager.deinit();

    // Test that federation manager initializes correctly
    try testing.expect(federation_manager.shards.items.len == 0);
    try testing.expect(federation_manager.coordinator_id == 0);

    // Register a shard and verify lookup
    try federation_manager.registerShard(.{
        .id = 1,
        .endpoint = "localhost:3141",
        .labels = &[_][]const u8{"Person"},
        .estimated_size = 5000,
        .status = .active,
    });
    try testing.expect(federation_manager.shards.items.len == 1);

    // Test label-based shard lookup
    const found = federation_manager.getShardByLabel("Person");
    try testing.expect(found != null);
    try testing.expectEqual(@as(u32, 1), found.?.id);

    const not_found = federation_manager.getShardByLabel("NonExistent");
    try testing.expect(not_found == null);
}

test "Query distribution analysis framework" {
    // Test the query analysis framework for distribution decisions
    const allocator = testing.allocator;

    var analysis = qp.DistributionAnalysis.init(allocator);
    defer analysis.deinit();

    // Test initial state
    try testing.expect(analysis.target_shards.items.len == 0);
    try testing.expect(analysis.label_affinities.count() == 0);

    // Test label affinity tracking
    try analysis.addLabelAffinity("Person");
    try testing.expect(analysis.label_affinities.count() == 1);
    try testing.expect(analysis.label_affinities.get("Person") != null);

    // Adding the same label is idempotent
    try analysis.addLabelAffinity("Person");
    try testing.expect(analysis.label_affinities.count() == 1);

    // Adding a different label increases the count
    try analysis.addLabelAffinity("Order");
    try testing.expect(analysis.label_affinities.count() == 2);
}

// GAP-D007: Test that estimateShardRows uses shard estimated_size as fallback
test "GAP-D007: estimateShardRows uses shard estimated_size fallback" {
    const allocator = testing.allocator;

    var fm = qp.FederationManager.init(allocator);
    defer fm.deinit();
    var planner = qp.DistributedQueryPlanner.init(allocator, &fm);
    defer planner.deinit();

    // Register a shard with estimated_size but no CBO stats
    try planner.shard_registry.shards.put(1, qp.ShardInfo{
        .id = 1,
        .endpoint = "localhost:3141",
        .labels = &.{},
        .estimated_size = 5000,
        .status = .active,
    });

    var analysis = qp.DistributionAnalysis.init(allocator);
    defer analysis.deinit();

    const estimate = planner.estimateShardRows(1, analysis);
    // Should return estimated_size (5000) instead of hardcoded 1000
    try testing.expectEqual(@as(usize, 5000), estimate);
}

// GAP-D007: Test that estimateShardCost uses cost model factors
test "GAP-D007: estimateShardCost factors in cpu and memory" {
    var cost_model = qp.DistributedCostModel.init();

    // Plan with operations: cost = plan_cost * cpu_factor + ops_count * memory_factor
    const plan_with_ops = qp.ShardLocalPlan{
        .operations = &[_]qp.ShardLocalPlan.Operation{ .scan, .filter, .project },
        .estimated_cost = 100.0,
    };

    const cost = cost_model.estimateShardCost(plan_with_ops);
    // 100.0 * 1.0 + 3 * 0.1 = 100.3
    try testing.expect(@abs(cost - 100.3) < 0.01);

    // Empty ops: cost = plan_cost * cpu_factor
    const plan_no_ops = qp.ShardLocalPlan{
        .operations = &.{},
        .estimated_cost = 100.0,
    };
    const cost_no_ops = cost_model.estimateShardCost(plan_no_ops);
    try testing.expectEqual(@as(f64, 100.0), cost_no_ops);
}

// GAP-D007: Test that estimateTotalCost responds to compression setting
test "GAP-D007: compression reduces total cost estimate" {
    const allocator = testing.allocator;
    var cost_model = qp.DistributedCostModel.init();

    var plan = qp.CoordinatorPlan.init(allocator);
    defer plan.deinit();
    try plan.target_shards.append(allocator, 1);
    try plan.target_shards.append(allocator, 2);

    const no_compress = cost_model.estimateTotalCost(plan, qp.TransferOptimization{ .compression = false, .batching = false });
    const with_compress = cost_model.estimateTotalCost(plan, qp.TransferOptimization{ .compression = true, .batching = false });

    try testing.expect(with_compress < no_compress);
}

// GAP-D007: Test addPropertyFilters stores property key/value pairs
test "GAP-D007: addPropertyFilters stores property filters from node patterns" {
    const allocator = testing.allocator;
    const ast = geode.ast;

    var analysis = qp.DistributionAnalysis.init(allocator);
    defer analysis.deinit();

    // Create property expressions (literals)
    var string_val = ast.Expr{ .String = "Alice" };
    var int_val = ast.Expr{ .Int = 30 };

    // Build properties array
    const properties = &[_]ast.Property{
        .{ .key = "name", .value = &string_val },
        .{ .key = "age", .value = &int_val },
    };

    try analysis.addPropertyFilters(properties);

    // Should have stored 2 property filters
    try testing.expectEqual(@as(usize, 2), analysis.property_filters.items.len);

    // First filter: name = "Alice"
    try testing.expect(std.mem.eql(u8, analysis.property_filters.items[0].property, "name"));
    try testing.expect(std.mem.eql(u8, analysis.property_filters.items[0].value, "Alice"));
    try testing.expectEqual(qp.PropertyFilter.FilterOperator.eq, analysis.property_filters.items[0].operator);

    // Second filter: age = <<int>>
    try testing.expect(std.mem.eql(u8, analysis.property_filters.items[1].property, "age"));
    try testing.expect(std.mem.eql(u8, analysis.property_filters.items[1].value, "<<int>>"));
}

// GAP-D007: Test addEdgePattern stores edge type affinities
test "GAP-D007: addEdgePattern tracks relationship type affinities" {
    const allocator = testing.allocator;
    const ast = geode.ast;

    var analysis = qp.DistributionAnalysis.init(allocator);
    defer analysis.deinit();

    // Create an edge pattern with types
    const rel = ast.RelPattern{
        .name = null,
        .types = @constCast(&[_][]const u8{ "KNOWS", "WORKS_AT" }),
        .props = null,
        .dir = .right,
    };

    try analysis.addEdgePattern(rel);

    // Should have 2 edge type affinities
    try testing.expectEqual(@as(u32, 2), analysis.edge_type_affinities.count());
    try testing.expect(analysis.edge_type_affinities.get("KNOWS") != null);
    try testing.expect(analysis.edge_type_affinities.get("WORKS_AT") != null);

    // Adding same edge type again should increment count
    try analysis.addEdgePattern(rel);
    try testing.expectEqual(@as(u32, 2), analysis.edge_type_affinities.count()); // Still 2 distinct types
    try testing.expectEqual(@as(u32, 2), analysis.edge_type_affinities.get("KNOWS").?); // But count is 2
}

// GAP-D007: Test addFilterCondition extracts property name and value from Binary expression
test "GAP-D007: addFilterCondition extracts property-based filters" {
    const allocator = testing.allocator;
    const ast = geode.ast;

    var analysis = qp.DistributionAnalysis.init(allocator);
    defer analysis.deinit();

    // Create a Binary expression: n.name = "Alice"
    var lhs = ast.Expr{ .PropertyAccess = .{ .object = "n", .property = "name" } };
    var rhs = ast.Expr{ .String = "Alice" };

    // The addFilterCondition takes the captured struct from Expr.Binary
    try analysis.addFilterCondition(.{ .op = .Eq, .left = &lhs, .right = &rhs });

    try testing.expectEqual(@as(usize, 1), analysis.property_filters.items.len);
    try testing.expect(std.mem.eql(u8, analysis.property_filters.items[0].property, "name"));
    try testing.expect(std.mem.eql(u8, analysis.property_filters.items[0].value, "Alice"));
    try testing.expectEqual(qp.PropertyFilter.FilterOperator.eq, analysis.property_filters.items[0].operator);
}

// GAP-D007: Test addFilterCondition with different comparison operators
test "GAP-D007: addFilterCondition preserves comparison operator" {
    const allocator = testing.allocator;
    const ast = geode.ast;

    var analysis = qp.DistributionAnalysis.init(allocator);
    defer analysis.deinit();

    var lhs = ast.Expr{ .PropertyAccess = .{ .object = "n", .property = "age" } };
    var rhs = ast.Expr{ .Int = 30 };

    try analysis.addFilterCondition(.{ .op = .Gt, .left = &lhs, .right = &rhs });

    try testing.expectEqual(@as(usize, 1), analysis.property_filters.items.len);
    try testing.expectEqual(qp.PropertyFilter.FilterOperator.gt, analysis.property_filters.items[0].operator);
}

// GAP-D007: Test addFunctionFilter extracts function name and arg count
test "GAP-D007: addFunctionFilter stores function name and arg count" {
    const allocator = testing.allocator;
    const ast = geode.ast;

    var analysis = qp.DistributionAnalysis.init(allocator);
    defer analysis.deinit();

    // Create a function call: geoHash(n.location)
    var callee = ast.Expr{ .Ident = .{ .orig = "geoHash", .cnf = "GEOHASH" } };
    var arg1 = ast.Expr{ .PropertyAccess = .{ .object = "n", .property = "location" } };

    try analysis.addFunctionFilter(.{ .callee = &callee, .args = @constCast(&[_]*ast.Expr{&arg1}) });

    try testing.expectEqual(@as(usize, 1), analysis.function_filters.items.len);
    try testing.expect(std.mem.eql(u8, analysis.function_filters.items[0].function_name, "GEOHASH"));
    try testing.expectEqual(@as(usize, 1), analysis.function_filters.items[0].arg_count);
}

// GAP-D007: Test planExecutionPhases returns 3 structured phases
test "GAP-D007: planExecutionPhases returns structured phases" {
    const allocator = testing.allocator;

    var fm = qp.FederationManager.init(allocator);
    defer fm.deinit();
    var planner = qp.DistributedQueryPlanner.init(allocator, &fm);
    defer planner.deinit();

    // Create shard plans to provide to the coordinator
    const shard_plan_1 = qp.ShardPlan{
        .shard_id = 1,
        .query = std.mem.zeroes(geode.ast.Query),
        .local_plan = qp.ShardLocalPlan{
            .operations = &[_]qp.ShardLocalPlan.Operation{ .scan, .filter, .project },
            .estimated_cost = 100.0,
        },
        .estimated_rows = 5000,
        .estimated_cost = 100.0,
        .data_transfer_size = 512 * 1024,
    };
    const shard_plan_2 = qp.ShardPlan{
        .shard_id = 2,
        .query = std.mem.zeroes(geode.ast.Query),
        .local_plan = qp.ShardLocalPlan{
            .operations = &[_]qp.ShardLocalPlan.Operation{ .scan, .project },
            .estimated_cost = 50.0,
        },
        .estimated_rows = 2000,
        .estimated_cost = 50.0,
        .data_transfer_size = 256 * 1024,
    };

    const shard_plans = &[_]qp.ShardPlan{ shard_plan_1, shard_plan_2 };

    // Create coordinator plan with shard plans and a join strategy
    var coordinator_plan = qp.CoordinatorPlan.init(allocator);
    defer coordinator_plan.deinit();
    coordinator_plan.shard_plans = shard_plans;
    coordinator_plan.join_strategy = .hash_join;
    coordinator_plan.aggregation_strategy = .two_phase;

    const optimization = qp.TransferOptimization{
        .compression = true,
        .batching = true,
    };

    const phases = try planner.planExecutionPhases(coordinator_plan, optimization);
    defer allocator.free(phases);

    // Should have exactly 3 phases
    try testing.expectEqual(@as(usize, 3), phases.len);

    // Phase 1: Parallel shard execution
    try testing.expectEqual(@as(u32, 1), phases[0].phase_id);
    try testing.expect(phases[0].operations.len > 0); // Has shard operations
    try testing.expect(phases[0].dependencies.len == 0); // No dependencies
    try testing.expect(phases[0].estimated_duration > 0);

    // Phase 2: Data transfer
    try testing.expectEqual(@as(u32, 2), phases[1].phase_id);
    try testing.expect(phases[1].operations.len > 0);
    try testing.expect(phases[1].dependencies.len == 1); // Depends on phase 1
    try testing.expectEqual(@as(u32, 1), phases[1].dependencies[0]);
    try testing.expect(phases[1].estimated_duration > 0);

    // Phase 3: Coordinator merge
    try testing.expectEqual(@as(u32, 3), phases[2].phase_id);
    try testing.expect(phases[2].operations.len > 0);
    try testing.expect(phases[2].dependencies.len == 1); // Depends on phase 2
    try testing.expectEqual(@as(u32, 2), phases[2].dependencies[0]);
    try testing.expect(phases[2].estimated_duration > 0);

    // Free allocated slices
    for (phases) |phase| {
        allocator.free(phase.operations);
        if (phase.dependencies.len > 0) {
            allocator.free(phase.dependencies);
        }
    }
}

// GAP-D007: Test planExecutionPhases phase 3 includes coordinator operations
test "GAP-D007: planExecutionPhases includes coordinator join and aggregate ops" {
    const allocator = testing.allocator;

    var fm = qp.FederationManager.init(allocator);
    defer fm.deinit();
    var planner = qp.DistributedQueryPlanner.init(allocator, &fm);
    defer planner.deinit();

    const shard_plan = qp.ShardPlan{
        .shard_id = 1,
        .query = std.mem.zeroes(geode.ast.Query),
        .local_plan = qp.ShardLocalPlan{
            .operations = &[_]qp.ShardLocalPlan.Operation{.scan},
            .estimated_cost = 50.0,
        },
        .estimated_rows = 1000,
        .estimated_cost = 50.0,
        .data_transfer_size = 128 * 1024,
    };

    var coordinator_plan = qp.CoordinatorPlan.init(allocator);
    defer coordinator_plan.deinit();
    coordinator_plan.shard_plans = &[_]qp.ShardPlan{shard_plan};
    coordinator_plan.join_strategy = .hash_join;
    coordinator_plan.aggregation_strategy = .two_phase;

    const optimization = qp.TransferOptimization{ .compression = false, .batching = false };

    const phases = try planner.planExecutionPhases(coordinator_plan, optimization);
    defer allocator.free(phases);

    // Phase 3 should contain join, aggregate, and result_merge
    const phase3 = phases[2];
    try testing.expect(phase3.operations.len >= 3); // join + aggregate + result_merge

    // Verify phase 3 has the right operation types
    var has_join = false;
    var has_aggregate = false;
    var has_merge = false;
    for (phase3.operations) |op| {
        if (op.operation_type == .coordinator_join) has_join = true;
        if (op.operation_type == .coordinator_aggregate) has_aggregate = true;
        if (op.operation_type == .result_merge) has_merge = true;
    }
    try testing.expect(has_join);
    try testing.expect(has_aggregate);
    try testing.expect(has_merge);

    // Free allocated slices
    for (phases) |phase| {
        allocator.free(phase.operations);
        if (phase.dependencies.len > 0) {
            allocator.free(phase.dependencies);
        }
    }
}

// GAP-D007: Test analyzeDataFlow uses actual shard plan transfer sizes
test "GAP-D007: analyzeDataFlow uses actual shard plan data" {
    const allocator = testing.allocator;

    var fm = qp.FederationManager.init(allocator);
    defer fm.deinit();
    var planner = qp.DistributedQueryPlanner.init(allocator, &fm);
    defer planner.deinit();

    // Create shard plans with known transfer sizes
    const shard_plans = &[_]qp.ShardPlan{
        .{
            .shard_id = 1,
            .query = std.mem.zeroes(geode.ast.Query),
            .local_plan = qp.ShardLocalPlan{ .operations = &.{}, .estimated_cost = 10.0 },
            .estimated_rows = 1000,
            .estimated_cost = 10.0,
            .data_transfer_size = 2 * 1024 * 1024, // 2MB
        },
        .{
            .shard_id = 2,
            .query = std.mem.zeroes(geode.ast.Query),
            .local_plan = qp.ShardLocalPlan{ .operations = &.{}, .estimated_cost = 10.0 },
            .estimated_rows = 1000,
            .estimated_cost = 10.0,
            .data_transfer_size = 3 * 1024 * 1024, // 3MB
        },
    };

    var coordinator_plan = qp.CoordinatorPlan.init(allocator);
    defer coordinator_plan.deinit();
    coordinator_plan.shard_plans = shard_plans;

    const data_flow = try planner.analyzeDataFlow(coordinator_plan);
    defer allocator.free(data_flow.bottlenecks);

    // Total transfer should be sum of shard transfers (2MB + 3MB = 5MB)
    try testing.expectEqual(@as(usize, 5 * 1024 * 1024), data_flow.total_transfer);
}

// GAP-D007: Test analyzeDataFlow identifies bottleneck shards
test "GAP-D007: analyzeDataFlow identifies bottleneck shards" {
    const allocator = testing.allocator;

    var fm = qp.FederationManager.init(allocator);
    defer fm.deinit();
    var planner = qp.DistributedQueryPlanner.init(allocator, &fm);
    defer planner.deinit();

    // Shard 1 transfers 10x more than shard 2 -- clear bottleneck
    const shard_plans = &[_]qp.ShardPlan{
        .{
            .shard_id = 1,
            .query = std.mem.zeroes(geode.ast.Query),
            .local_plan = qp.ShardLocalPlan{ .operations = &.{}, .estimated_cost = 10.0 },
            .estimated_rows = 1000,
            .estimated_cost = 10.0,
            .data_transfer_size = 10 * 1024 * 1024, // 10MB
        },
        .{
            .shard_id = 2,
            .query = std.mem.zeroes(geode.ast.Query),
            .local_plan = qp.ShardLocalPlan{ .operations = &.{}, .estimated_cost = 10.0 },
            .estimated_rows = 1000,
            .estimated_cost = 10.0,
            .data_transfer_size = 1 * 1024 * 1024, // 1MB
        },
    };

    var coordinator_plan = qp.CoordinatorPlan.init(allocator);
    defer coordinator_plan.deinit();
    coordinator_plan.shard_plans = shard_plans;

    const data_flow = try planner.analyzeDataFlow(coordinator_plan);
    defer allocator.free(data_flow.bottlenecks);

    // Total should be 11MB
    try testing.expectEqual(@as(usize, 11 * 1024 * 1024), data_flow.total_transfer);

    // Should identify shard 1 as a bottleneck (10MB > 2 * average of 5.5MB)
    try testing.expect(data_flow.bottlenecks.len >= 1);
    try testing.expectEqual(@as(u32, 1), data_flow.bottlenecks[0].shard_id);
    try testing.expect(data_flow.bottlenecks[0].severity > 1.0);
}

// GAP-D007: Test analyzeDataFlow falls back when no shard plans
test "GAP-D007: analyzeDataFlow falls back to per-shard baseline without shard plans" {
    const allocator = testing.allocator;

    var fm = qp.FederationManager.init(allocator);
    defer fm.deinit();
    var planner = qp.DistributedQueryPlanner.init(allocator, &fm);
    defer planner.deinit();

    // Coordinator plan with no shard plans attached
    var coordinator_plan = qp.CoordinatorPlan.init(allocator);
    defer coordinator_plan.deinit();
    try coordinator_plan.target_shards.append(allocator, 1);
    try coordinator_plan.target_shards.append(allocator, 2);
    try coordinator_plan.target_shards.append(allocator, 3);
    // shard_plans is default &.{} (empty)

    const data_flow = try planner.analyzeDataFlow(coordinator_plan);

    // Falls back to 1MB per shard * 3 shards = 3MB
    try testing.expectEqual(@as(usize, 3 * 1024 * 1024), data_flow.total_transfer);
    try testing.expectEqual(@as(usize, 0), data_flow.bottlenecks.len);
}

// GAP-D007: Test DistributionAnalysis cleanup (new fields are freed properly)
test "GAP-D007: DistributionAnalysis properly deinits new fields" {
    const allocator = testing.allocator;
    const ast = geode.ast;

    var analysis = qp.DistributionAnalysis.init(allocator);

    // Populate all the new fields
    var string_val = ast.Expr{ .String = "test" };
    try analysis.addPropertyFilters(&[_]ast.Property{.{ .key = "k", .value = &string_val }});

    try analysis.addEdgePattern(ast.RelPattern{
        .name = null,
        .types = @constCast(&[_][]const u8{"KNOWS"}),
        .props = null,
        .dir = .right,
    });

    var callee = ast.Expr{ .Ident = .{ .orig = "fn", .cnf = "FN" } };
    try analysis.addFunctionFilter(.{ .callee = &callee, .args = @constCast(&[_]*ast.Expr{}) });

    // Verify populated
    try testing.expect(analysis.property_filters.items.len > 0);
    try testing.expect(analysis.edge_type_affinities.count() > 0);
    try testing.expect(analysis.function_filters.items.len > 0);

    // deinit should not leak (allocator will detect leaks)
    analysis.deinit();
}
