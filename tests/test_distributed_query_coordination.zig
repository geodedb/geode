// CANARY: REQ=REQ-DIST-QUERY-COORD-TEST-001; FEATURE="Distributed Query Coordination Tests"; ASPECT=UnitTests; STATUS=IMPL; TEST=TestCANARY_REQ_DIST_QUERY_COORD_TEST_001_UnitTests; OWNER=dist; UPDATED=2025-10-05

const std = @import("std");
const testing = std.testing;
const query_transport = @import("../src/distributed/query_transport.zig");
const enhanced_coordinator = @import("../src/distributed/enhanced_query_coordinator.zig");
const network_transport = @import("../src/distributed/network_transport.zig");
const federation = @import("../src/distributed/federation.zig");
const protocol = @import("../src/protocol.zig");

test "QueryTransport initialization and cleanup" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Mock network transport
    var mock_network = MockNetworkTransport.init(allocator);
    defer mock_network.deinit();
    
    // Initialize query transport
    var transport = try query_transport.QueryTransport.init(allocator, &mock_network.transport);
    defer transport.deinit();
    
    try testing.expect(transport.timeout_ms == 30000);
    try testing.expect(transport.retry_attempts == 3);
}

test "Enhanced query coordinator initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Mock network transport
    var mock_network = MockNetworkTransport.init(allocator);
    defer mock_network.deinit();
    
    const config = federation.FederationConfig{
        .cluster_name = "test-cluster",
        .node_id = 1,
        .max_shards = 10,
    };
    
    // Initialize enhanced coordinator
    var coordinator = try enhanced_coordinator.EnhancedQueryCoordinator.init(
        allocator, 
        config, 
        &mock_network.transport
    );
    defer coordinator.deinit();
    
    const metrics = coordinator.getMetrics();
    try testing.expect(metrics.total_queries == 0);
    try testing.expect(metrics.cache_hits == 0);
}

test "Query analysis for different query types" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var mock_network = MockNetworkTransport.init(allocator);
    defer mock_network.deinit();
    
    const config = federation.FederationConfig{
        .cluster_name = "test-cluster",
        .node_id = 1,
        .max_shards = 10,
    };
    
    var coordinator = try enhanced_coordinator.EnhancedQueryCoordinator.init(
        allocator, 
        config, 
        &mock_network.transport
    );
    defer coordinator.deinit();
    
    // Test MATCH query analysis
    const match_query = "MATCH (p:Person) WHERE p.age > 25 ORDER BY p.name RETURN p";
    var match_analysis = try coordinator.analyzeQuery(match_query);
    defer match_analysis.deinit();
    
    try testing.expect(match_analysis.query_type == .match_query);
    try testing.expect(match_analysis.has_global_ordering == true);
    try testing.expect(match_analysis.referenced_labels.items.len > 0);
    
    // Test CREATE query analysis
    const create_query = "CREATE (n:Node {id: 123})";
    var create_analysis = try coordinator.analyzeQuery(create_query);
    defer create_analysis.deinit();
    
    try testing.expect(create_analysis.query_type == .create_query);
    try testing.expect(create_analysis.has_global_ordering == false);
    
    // Test aggregation query
    const agg_query = "MATCH (p:Person) RETURN COUNT(p)";
    var agg_analysis = try coordinator.analyzeQuery(agg_query);
    defer agg_analysis.deinit();
    
    try testing.expect(agg_analysis.has_aggregation == true);
}

test "Union all results merging" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var mock_network = MockNetworkTransport.init(allocator);
    defer mock_network.deinit();
    
    const config = federation.FederationConfig{
        .cluster_name = "test-cluster",
        .node_id = 1,
        .max_shards = 10,
    };
    
    var coordinator = try enhanced_coordinator.EnhancedQueryCoordinator.init(
        allocator, 
        config, 
        &mock_network.transport
    );
    defer coordinator.deinit();
    
    // Create mock shard results
    var shard_results = [_]federation.QueryResults{
        federation.QueryResults{
            .rows = &[_]protocol.BindingRow{
                &[_]protocol.Binding{
                    protocol.Binding{ .value = protocol.Value{ .String = "Alice" } },
                },
                &[_]protocol.Binding{
                    protocol.Binding{ .value = protocol.Value{ .String = "Bob" } },
                },
            },
            .schema = &[_]protocol.Column{
                protocol.Column{ .name = "name", .type = "STRING" },
            },
            .execution_time_ms = 10,
            .ordered = false,
        },
        federation.QueryResults{
            .rows = &[_]protocol.BindingRow{
                &[_]protocol.Binding{
                    protocol.Binding{ .value = protocol.Value{ .String = "Charlie" } },
                },
            },
            .schema = &[_]protocol.Column{
                protocol.Column{ .name = "name", .type = "STRING" },
            },
            .execution_time_ms = 15,
            .ordered = false,
        },
    };
    
    const options = enhanced_coordinator.QueryOptions{};
    
    // Test union all merge
    const merged = try coordinator.unionAllResults(&shard_results, options);
    defer allocator.free(merged.rows);
    
    try testing.expect(merged.rows.len == 3);
    try testing.expect(merged.ordered == false);
    try testing.expect(merged.schema.len == 1);
}

test "Query cache functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var cache = try enhanced_coordinator.QueryCache.init(allocator);
    defer cache.deinit();
    
    const query = "MATCH (n) RETURN n";
    const params = [_]protocol.Value{};
    
    // Test cache miss
    const query_hash = try cache.hashQuery(query, &params);
    defer allocator.free(query_hash);
    
    const cached_result = try cache.get(query_hash);
    try testing.expect(cached_result == null);
    
    // Test cache put and hit
    const result = federation.QueryResults{
        .rows = &.{},
        .schema = &.{},
        .execution_time_ms = 100,
        .ordered = false,
    };
    
    try cache.put(query_hash, result, 60000); // 1 minute TTL
    
    const cached_result2 = try cache.get(query_hash);
    try testing.expect(cached_result2 != null);
    try testing.expect(cached_result2.?.execution_time_ms == 100);
}

test "Query options and limits" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var mock_network = MockNetworkTransport.init(allocator);
    defer mock_network.deinit();
    
    const config = federation.FederationConfig{
        .cluster_name = "test-cluster",
        .node_id = 1,
        .max_shards = 10,
    };
    
    var coordinator = try enhanced_coordinator.EnhancedQueryCoordinator.init(
        allocator, 
        config, 
        &mock_network.transport
    );
    defer coordinator.deinit();
    
    // Create test data with more rows than limit
    var shard_results = [_]federation.QueryResults{
        federation.QueryResults{
            .rows = &[_]protocol.BindingRow{
                &[_]protocol.Binding{
                    protocol.Binding{ .value = protocol.Value{ .String = "Row1" } },
                },
                &[_]protocol.Binding{
                    protocol.Binding{ .value = protocol.Value{ .String = "Row2" } },
                },
                &[_]protocol.Binding{
                    protocol.Binding{ .value = protocol.Value{ .String = "Row3" } },
                },
                &[_]protocol.Binding{
                    protocol.Binding{ .value = protocol.Value{ .String = "Row4" } },
                },
            },
            .schema = &[_]protocol.Column{
                protocol.Column{ .name = "data", .type = "STRING" },
            },
            .execution_time_ms = 10,
            .ordered = false,
        },
    };
    
    // Test with limit
    const options_with_limit = enhanced_coordinator.QueryOptions{
        .limit = 2,
        .offset = 1,
    };
    
    const limited_result = try coordinator.unionAllResults(&shard_results, options_with_limit);
    defer allocator.free(limited_result.rows);
    
    try testing.expect(limited_result.rows.len == 2);
}

test "Coordinator metrics tracking" {
    var metrics = enhanced_coordinator.CoordinatorMetrics.init();
    
    try testing.expect(metrics.total_queries == 0);
    try testing.expect(metrics.cache_hits == 0);
    
    // Record some operations
    metrics.recordQuery(100, 3);
    metrics.recordCacheHit();
    metrics.recordMergeTime(50);
    
    try testing.expect(metrics.total_queries == 1);
    try testing.expect(metrics.total_time_ms == 100);
    try testing.expect(metrics.shard_queries == 3);
    try testing.expect(metrics.cache_hits == 1);
    try testing.expect(metrics.merge_time_ms == 50);
}

test "Row hashing for deduplication" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var mock_network = MockNetworkTransport.init(allocator);
    defer mock_network.deinit();
    
    const config = federation.FederationConfig{
        .cluster_name = "test-cluster",
        .node_id = 1,
        .max_shards = 10,
    };
    
    var coordinator = try enhanced_coordinator.EnhancedQueryCoordinator.init(
        allocator, 
        config, 
        &mock_network.transport
    );
    defer coordinator.deinit();
    
    const row1 = &[_]protocol.Binding{
        protocol.Binding{ .value = protocol.Value{ .String = "Alice" } },
    };
    
    const row2 = &[_]protocol.Binding{
        protocol.Binding{ .value = protocol.Value{ .String = "Alice" } },
    };
    
    const row3 = &[_]protocol.Binding{
        protocol.Binding{ .value = protocol.Value{ .String = "Bob" } },
    };
    
    const hash1 = try coordinator.hashRow(row1);
    defer allocator.free(hash1);
    
    const hash2 = try coordinator.hashRow(row2);
    defer allocator.free(hash2);
    
    const hash3 = try coordinator.hashRow(row3);
    defer allocator.free(hash3);
    
    // Same content should produce same hash
    try testing.expectEqualStrings(hash1, hash2);
    
    // Different content should produce different hash
    try testing.expect(!std.mem.eql(u8, hash1, hash3));
}

test "Distributed plan optimization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var optimizer = try enhanced_coordinator.DistributedQueryOptimizer.init(allocator);
    defer optimizer.deinit();
    
    var shard_registry = try enhanced_coordinator.ShardRegistry.init(allocator);
    defer shard_registry.deinit();
    
    // Test query analysis
    var analysis = enhanced_coordinator.QueryAnalysis.init(allocator);
    defer analysis.deinit();
    
    analysis.query_type = .match_query;
    analysis.has_global_ordering = true;
    analysis.estimated_selectivity = 0.1;
    
    // Optimize query
    var plan = try optimizer.optimizeQuery(analysis, &shard_registry);
    defer plan.deinit();
    
    try testing.expect(plan.fragments.len > 0);
    try testing.expect(plan.merge_strategy == .merge_sorted); // Due to global ordering
    try testing.expect(plan.estimated_cost > 0);
}

test "Connection pool management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var pool = try query_transport.ConnectionPool.init(allocator);
    defer pool.deinit();
    
    // Test getting connections
    const conn1 = try pool.getConnection(1);
    const conn2 = try pool.getConnection(1); // Should reuse
    const conn3 = try pool.getConnection(2); // Different node
    
    try testing.expect(conn1 == conn2); // Same connection reused
    try testing.expect(conn1 != conn3); // Different nodes have different connections
    
    // Test connection health
    try testing.expect(conn1.isHealthy() == false); // Not connected yet
    
    pool.releaseConnection(conn1);
    pool.releaseConnection(conn3);
}

// Mock implementations for testing

const MockNetworkTransport = struct {
    allocator: std.mem.Allocator,
    transport: network_transport.NetworkTransport,
    
    fn init(allocator: std.mem.Allocator) MockNetworkTransport {
        return MockNetworkTransport{
            .allocator = allocator,
            .transport = network_transport.NetworkTransport{
                .allocator = allocator,
                .node_id = 1,
                .quic_transport = undefined, // Mock
                .peers = std.AutoHashMap(u32, network_transport.NetworkTransport.PeerConnection).init(allocator),
                .message_handler = null,
                .mutex = .{},
            },
        };
    }
    
    fn deinit(self: *MockNetworkTransport) void {
        self.transport.peers.deinit();
    }
};