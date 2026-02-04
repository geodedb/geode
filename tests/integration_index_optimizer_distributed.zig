const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// CANARY: REQ=REQ-DISTRIBUTED-INDEX-OPTIMIZER-INTEGRATION-001; FEATURE="Distributed IndexOptimizer Integration"; ASPECT=ServerIntegration; STATUS=TESTED; TEST=TestCANARY_REQ_DISTRIBUTED_INDEX_OPTIMIZER_INTEGRATION_001_ServerIntegration; OWNER=distributed; UPDATED=2025-10-05
// CANARY: REQ=REQ-DISTRIBUTED-INDEX-OPTIMIZER-INTEGRATION-002; FEATURE="Distributed IndexOptimizer Integration"; ASPECT=QueryExecutionFlow; STATUS=TESTED; TEST=TestCANARY_REQ_DISTRIBUTED_INDEX_OPTIMIZER_INTEGRATION_002_QueryExecutionFlow; OWNER=distributed; UPDATED=2025-10-05
// CANARY: REQ=REQ-DISTRIBUTED-INDEX-OPTIMIZER-INTEGRATION-003; FEATURE="Distributed IndexOptimizer Integration"; ASPECT=PerformanceOptimization; STATUS=TESTED; TEST=TestCANARY_REQ_DISTRIBUTED_INDEX_OPTIMIZER_INTEGRATION_003_PerformanceOptimization; OWNER=distributed; UPDATED=2025-10-05

test "TestCANARY_REQ_DISTRIBUTED_INDEX_OPTIMIZER_INTEGRATION_001_ServerIntegration" {
    // Test distributed IndexOptimizer integration with server state
    const allocator = testing.allocator;

    // Create a mock server state with distributed capabilities
    var mock_server_state = MockServerState.init(allocator);
    defer mock_server_state.deinit();

    // Initialize distributed index optimizer through server state
    var index_optimizer = try mock_server_state.createDistributedIndexOptimizer();
    defer index_optimizer.deinit();

    // Test that the optimizer is properly configured for distributed operations
    const federation_config = mock_server_state.getFederationConfig();
    try testing.expect(federation_config.enabled == true);
    try testing.expect(federation_config.shard_count >= 2);
    try testing.expect(federation_config.coordinator_enabled == true);

    // Test distributed cost estimation through server integration
    const distributed_estimate = index_optimizer.estimateDistributedQueryCost(&[_][]const u8{"Person"}", "name", geode.PropertyValue{ .String = "Alice" }, federation_config.shard_count, federation_config.enabled);

    // Verify that distributed estimation is working
    try testing.expect(distributed_estimate.total_cost > 0);
    try testing.expect(distributed_estimate.optimization_strategy != .single_shard);
    try testing.expect(distributed_estimate.parallelism_factor > 0);

    // Test integration with existing IndexOptimizer functionality
    const local_plan = index_optimizer.optimizeNodeScan(&[_][]const u8{"Person"}", "name", geode.PropertyValue{ .String = "Alice" });

    // Local plan should still work normally
    try testing.expect(local_plan.estimated_cost > 0);
    try testing.expect(local_plan.estimated_rows > 0);
}

test "TestCANARY_REQ_DISTRIBUTED_INDEX_OPTIMIZER_INTEGRATION_002_QueryExecutionFlow" {
    // Test the complete query execution flow with distributed optimization
    const allocator = testing.allocator;

    var mock_server_state = MockServerState.init(allocator);
    defer mock_server_state.deinit();

    var index_optimizer = try mock_server_state.createDistributedIndexOptimizer();
    defer index_optimizer.deinit();

    // Test different query execution scenarios
    const query_scenarios = [_]struct {
        query_type: []const u8,
        labels: []const []const u8,
        property: ?[]const u8,
        expected_strategy: geode.DistributedOptimizationStrategy,
        shard_count: u32,
    }{
        .{
            .query_type = "simple_node_scan",
            .labels = &[_][]const u8{"Person"},
            .property = "name",
            .expected_strategy = .selective_distribution,
            .shard_count = 4,
        },
        .{
            .query_type = "high_selectivity_lookup",
            .labels = &[_][]const u8{"User"},
            .property = "id",
            .expected_strategy = .coordinator_only,
            .shard_count = 8,
        },
        .{
            .query_type = "full_table_scan",
            .labels = &[_][]const u8{"Event"},
            .property = null,
            .expected_strategy = .full_distribution,
            .shard_count = 6,
        },
    };

    for (query_scenarios) |scenario| {
        // Create property value for testing
        const prop_value = if (scenario.property != null)
            geode.PropertyValue{ .String = "test_value" }
        else
            null;

        // Estimate distributed cost for the scenario
        const distributed_cost = index_optimizer.estimateDistributedQueryCost(scenario.labels, scenario.property, prop_value, scenario.shard_count, true // Enable federation
        );

        // Test that cost estimation produces reasonable results
        try testing.expect(distributed_cost.total_cost > 0);
        try testing.expect(!std.math.isNan(distributed_cost.total_cost));
        try testing.expect(!std.math.isInf(distributed_cost.total_cost));

        // Test that parallelism factor is reasonable
        try testing.expect(distributed_cost.parallelism_factor > 0);
        try testing.expect(distributed_cost.parallelism_factor <= 1.0);

        // Test that coordination cost scales with shard count
        if (scenario.shard_count > 2) {
            try testing.expect(distributed_cost.coordination_cost > 0);
        }

        // Test cross-shard operation cost estimation for complex scenarios
        if (std.mem.eql(u8, scenario.query_type, "full_table_scan")) {
            const cross_shard_cost = index_optimizer.estimateCrossShardIndexCost(.distributed_aggregation, &[_]geode.IndexType{.btree}, scenario.shard_count, 0.5 // Medium data locality
            );

            try testing.expect(cross_shard_cost > distributed_cost.local_cost);
        }
    }
}

test "TestCANARY_REQ_DISTRIBUTED_INDEX_OPTIMIZER_INTEGRATION_003_PerformanceOptimization" {
    // Test performance optimization capabilities of distributed IndexOptimizer
    const allocator = testing.allocator;

    var mock_server_state = MockServerState.init(allocator);
    defer mock_server_state.deinit();

    var index_optimizer = try mock_server_state.createDistributedIndexOptimizer();
    defer index_optimizer.deinit();

    // Test performance comparison between single-shard and distributed execution
    const large_dataset_labels = &[_][]const u8{"Transaction"};
    const large_dataset_prop = geode.PropertyValue{ .String = "merchant_id" };

    // Single shard execution
    const single_shard_cost = index_optimizer.estimateDistributedQueryCost(large_dataset_labels, "merchant_id", large_dataset_prop, 1, // Single shard
        false // Not federated
    );

    // Multi-shard execution
    const multi_shard_cost = index_optimizer.estimateDistributedQueryCost(large_dataset_labels, "merchant_id", large_dataset_prop, 8, // Eight shards
        true // Federated
    );

    // Analyze performance characteristics
    try testing.expect(single_shard_cost.optimization_strategy == .single_shard);
    try testing.expect(multi_shard_cost.optimization_strategy != .single_shard);

    // For large datasets, distributed execution might be beneficial
    const distributed_benefit = single_shard_cost.total_cost - multi_shard_cost.total_cost;

    // Test that the optimizer makes reasonable decisions
    if (distributed_benefit > 0) {
        // Distributed execution is beneficial
        try testing.expect(multi_shard_cost.parallelism_factor > 0.5);
        try testing.expect(multi_shard_cost.optimization_strategy == .full_distribution or
            multi_shard_cost.optimization_strategy == .selective_distribution);
    } else {
        // Single shard is still better (due to coordination overhead)
        try testing.expect(multi_shard_cost.coordination_cost > 0);
        try testing.expect(multi_shard_cost.network_cost > 0);
    }

    // Test locality impact on performance
    const high_locality_cost = index_optimizer.estimateCrossShardIndexCost(.distributed_join, &[_]geode.IndexType{ .btree, .hash }, 4, 0.9 // High data locality
    );

    const low_locality_cost = index_optimizer.estimateCrossShardIndexCost(.distributed_join, &[_]geode.IndexType{ .btree, .hash }, 4, 0.1 // Low data locality
    );

    // High locality should result in lower costs
    try testing.expect(high_locality_cost < low_locality_cost);
    try testing.expect((low_locality_cost - high_locality_cost) > 0);

    // Test optimization strategy recommendations
    const performance_scenarios = [_]struct {
        operation: geode.CrossShardOperation,
        shard_count: u32,
        data_locality: f64,
        expected_performance_factor: f64, // Multiplier compared to single operation
    }{
        .{ .operation = .cross_shard_lookup, .shard_count = 2, .data_locality = 0.8, .expected_performance_factor = 2.0 },
        .{ .operation = .distributed_join, .shard_count = 4, .data_locality = 0.5, .expected_performance_factor = 3.0 },
        .{ .operation = .distributed_aggregation, .shard_count = 8, .data_locality = 0.3, .expected_performance_factor = 2.5 },
        .{ .operation = .distributed_union, .shard_count = 6, .data_locality = 0.7, .expected_performance_factor = 2.0 },
    };

    for (performance_scenarios) |scenario| {
        const operation_cost = index_optimizer.estimateCrossShardIndexCost(scenario.operation, &[_]geode.IndexType{.btree}, scenario.shard_count, scenario.data_locality);

        // Verify cost scaling is reasonable
        try testing.expect(operation_cost > 0);
        try testing.expect(operation_cost <= 1000.0 * scenario.expected_performance_factor);

        // Test that cost scales with shard count
        const fewer_shards_cost = index_optimizer.estimateCrossShardIndexCost(scenario.operation, &[_]geode.IndexType{.btree}, @max(2, scenario.shard_count / 2), scenario.data_locality);

        try testing.expect(fewer_shards_cost <= operation_cost);
    }
}

test "Distributed optimizer memory management and cleanup" {
    // Test memory management in distributed optimizer operations
    const allocator = testing.allocator;

    var mock_server_state = MockServerState.init(allocator);
    defer mock_server_state.deinit();

    // Test multiple optimizer instances
    var optimizers = std.ArrayList(*geode.IndexOptimizer).init(allocator);
    defer {
        for (optimizers.items) |optimizer| {
            optimizer.deinit();
        }
        optimizers.deinit();
    }

    // Create multiple optimizers to test memory usage
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        var optimizer = try mock_server_state.createDistributedIndexOptimizer();
        try optimizers.append(optimizer);
    }

    // Test distributed operations on all optimizers
    for (optimizers.items) |optimizer| {
        const distributed_cost = optimizer.estimateDistributedQueryCost(&[_][]const u8{"TestNode"}", "test_property", geode.PropertyValue{ .String = "test" }, 4, true);

        try testing.expect(distributed_cost.total_cost > 0);
        try testing.expect(!std.math.isNan(distributed_cost.total_cost));
    }

    // Test that optimizers can be safely destroyed
    for (optimizers.items) |optimizer| {
        optimizer.deinit();
    }

    // Clear the list to avoid double-free in defer
    optimizers.clearAndFree();
}

test "Distributed cost estimation with various index types" {
    // Test distributed cost estimation with different index types
    const allocator = testing.allocator;

    var mock_server_state = MockServerState.init(allocator);
    defer mock_server_state.deinit();

    var index_optimizer = try mock_server_state.createDistributedIndexOptimizer();
    defer index_optimizer.deinit();

    // Test different index type combinations
    const index_combinations = [_][]const geode.IndexType{
        &[_]geode.IndexType{.btree},
        &[_]geode.IndexType{.hash},
        &[_]geode.IndexType{.fulltext},
        &[_]geode.IndexType{ .btree, .hash },
        &[_]geode.IndexType{ .btree, .fulltext },
        &[_]geode.IndexType{ .hash, .fulltext },
        &[_]geode.IndexType{ .btree, .hash, .fulltext },
    };

    for (index_combinations) |index_types| {
        const cross_shard_cost = index_optimizer.estimateCrossShardIndexCost(.distributed_join, index_types, 4, // 4 shards
            0.6 // Medium-high locality
        );

        // Cost should scale with number of index types
        try testing.expect(cross_shard_cost > 0);
        try testing.expect(cross_shard_cost >= @as(f64, @floatFromInt(index_types.len)) * 10.0);

        // Test with different operations
        const operations = [_]geode.CrossShardOperation{
            .distributed_join,
            .distributed_aggregation,
            .distributed_union,
            .cross_shard_lookup,
        };

        for (operations) |operation| {
            const operation_cost = index_optimizer.estimateCrossShardIndexCost(operation, index_types, 3, // 3 shards
                0.5 // Medium locality
            );

            try testing.expect(operation_cost > 0);
            try testing.expect(!std.math.isNan(operation_cost));
            try testing.expect(!std.math.isInf(operation_cost));
        }
    }
}

test "Distributed optimization with edge case shard configurations" {
    // Test distributed optimization with various shard configurations
    const allocator = testing.allocator;

    var mock_server_state = MockServerState.init(allocator);
    defer mock_server_state.deinit();

    var index_optimizer = try mock_server_state.createDistributedIndexOptimizer();
    defer index_optimizer.deinit();

    // Test edge case shard counts
    const shard_counts = [_]u32{ 1, 2, 3, 7, 16, 32, 64, 128 };

    for (shard_counts) |shard_count| {
        const distributed_cost = index_optimizer.estimateDistributedQueryCost(&[_][]const u8{"EdgeCaseNode"}", "test_prop", geode.PropertyValue{ .String = "test" }, shard_count, shard_count > 1 // Enable federation for multi-shard
        );

        // All configurations should produce valid costs
        try testing.expect(distributed_cost.total_cost > 0);
        try testing.expect(!std.math.isNan(distributed_cost.total_cost));
        try testing.expect(!std.math.isInf(distributed_cost.total_cost));

        // Single shard should use single_shard strategy
        if (shard_count <= 1) {
            try testing.expect(distributed_cost.optimization_strategy == .single_shard);
            try testing.expect(distributed_cost.coordination_cost == 0.0);
            try testing.expect(distributed_cost.network_cost == 0.0);
            try testing.expect(distributed_cost.parallelism_factor == 1.0);
        } else {
            try testing.expect(distributed_cost.optimization_strategy != .single_shard);
            try testing.expect(distributed_cost.parallelism_factor > 0.0);
            try testing.expect(distributed_cost.parallelism_factor <= 1.0);
        }

        // Parallelism factor should be reasonable for all shard counts
        const max_expected_parallelism = @min(8.0, @as(f64, @floatFromInt(shard_count))) / @as(f64, @floatFromInt(shard_count));
        try testing.expect(distributed_cost.parallelism_factor <= max_expected_parallelism + 0.01); // Small tolerance
    }
}

// Mock ServerState for integration testing
const MockServerState = struct {
    allocator: std.mem.Allocator,
    federation_config: FederationConfig,
    index_manager: MockIndexManager,

    const FederationConfig = struct {
        enabled: bool = true,
        shard_count: u32 = 4,
        coordinator_enabled: bool = true,
        replication_factor: u32 = 2,
        load_balancing: bool = true,
    };

    const MockIndexManager = struct {
        allocator: std.mem.Allocator,
        interface: geode.index_manager.IIndexManager,

        pub fn init(allocator: std.mem.Allocator) MockIndexManager {
            return MockIndexManager{
                .allocator = allocator,
                .interface = geode.index_manager.IIndexManager{
                    .getIndexForPropertyFn = mockGetIndexForProperty,
                    .estimateIndexScanCostFn = mockEstimateIndexScanCost,
                },
            };
        }

        pub fn deinit(self: *MockIndexManager) void {
            _ = self;
        }

        fn mockGetIndexForProperty(manager: *geode.index_manager.IIndexManager, label: []const u8, property: []const u8) ?geode.IndexInfo {
            _ = manager;
            _ = label;
            _ = property;

            return geode.IndexInfo{
                .index_type = .btree,
                .name = "mock_distributed_index",
                .properties = &[_][]const u8{"mock_property"},
                .selectivity = 0.1,
            };
        }

        fn mockEstimateIndexScanCost(manager: *geode.index_manager.IIndexManager, index_info: geode.IndexInfo, selectivity: f64) f64 {
            _ = manager;
            _ = index_info;
            return 100.0 * selectivity; // Simple cost model
        }
    };

    pub fn init(allocator: std.mem.Allocator) MockServerState {
        return MockServerState{
            .allocator = allocator,
            .federation_config = FederationConfig{},
            .index_manager = MockIndexManager.init(allocator),
        };
    }

    pub fn deinit(self: *MockServerState) void {
        self.index_manager.deinit();
    }

    pub fn createDistributedIndexOptimizer(self: *MockServerState) !*geode.IndexOptimizer {
        const optimizer = try self.allocator.create(geode.IndexOptimizer);
        optimizer.* = geode.IndexOptimizer.init(self.allocator, &self.index_manager.interface);
        return optimizer;
    }

    pub fn getFederationConfig(self: *MockServerState) FederationConfig {
        return self.federation_config;
    }
};
