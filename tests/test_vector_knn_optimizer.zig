const std = @import("std");
const testing = std.testing;
const graph_common = @import("../src/types/graph_common.zig");
const IndexOptimizer = @import("../src/server/index_optimizer.zig").IndexOptimizer;
const VectorKNNOptimizer = @import("../src/server/index_optimizer.zig").VectorKNNOptimizer;

// Tests for Vector K-NN optimization integration with IndexOptimizer
// CANARY: REQ=REQ-GQL-203; FEATURE="VectorKNNOptimization"; ASPECT=IndexOptimization; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_203_VectorKNNOptimization; OWNER=index; UPDATED=2025-10-04

// Mock index manager for testing
const MockIndexManager = struct {
    allocator: std.mem.Allocator,
    vector_indexes: std.StringHashMap(MockVectorIndex),
    property_indexes: std.StringHashMap(std.ArrayList(graph_common.IndexInfo)),

    const MockVectorIndex = struct {
        dimension: u16,
        metric: []const u8,
        size: u64,

        pub fn searchVectorF32(self: *const MockVectorIndex, query: anytype, k: usize) !MockSearchResult {
            _ = self;
            _ = query;

            // Return mock results
            var results = std.ArrayList(MockMatch).init(std.testing.allocator);
            var i: u64 = 1;
            while (i <= @min(k, 10)) : (i += 1) {
                try results.append(MockMatch{
                    .id = i,
                    .score = @as(f64, @floatFromInt(i)) * 0.1,
                });
            }

            return MockSearchResult{ .results = results };
        }
    };

    const MockMatch = struct {
        id: u64,
        score: f64,
    };

    const MockSearchResult = struct {
        results: std.ArrayList(MockMatch),

        pub fn deinit(self: *const MockSearchResult) void {
            self.results.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator) MockIndexManager {
        return MockIndexManager{
            .allocator = allocator,
            .vector_indexes = std.StringHashMap(MockVectorIndex).init(allocator),
            .property_indexes = std.StringHashMap(std.ArrayList(graph_common.IndexInfo)).init(allocator),
        };
    }

    pub fn deinit(self: *MockIndexManager) void {
        var prop_it = self.property_indexes.valueIterator();
        while (prop_it.next()) |list| {
            list.deinit();
        }
        self.property_indexes.deinit();
        self.vector_indexes.deinit();
    }

    pub fn addVectorIndex(self: *MockIndexManager, name: []const u8, dimension: u16, metric: []const u8, size: u64) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        const owned_metric = try self.allocator.dupe(u8, metric);
        try self.vector_indexes.put(owned_name, MockVectorIndex{
            .dimension = dimension,
            .metric = owned_metric,
            .size = size,
        });
    }

    pub fn addPropertyIndex(self: *MockIndexManager, property: []const u8, index_info: graph_common.IndexInfo) !void {
        const result = try self.property_indexes.getOrPut(property);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(graph_common.IndexInfo).init(self.allocator);
        }
        try result.value_ptr.append(index_info);
    }

    pub fn getIndexesForProperty(self: *MockIndexManager, property: []const u8) ![]graph_common.IndexInfo {
        if (self.property_indexes.get(property)) |indexes| {
            return try self.allocator.dupe(graph_common.IndexInfo, indexes.items);
        }
        return &[_]graph_common.IndexInfo{};
    }

    pub fn getVectorIndex(self: *MockIndexManager, name: []const u8) !*const MockVectorIndex {
        return &(self.vector_indexes.get(name) orelse return error.IndexNotFound);
    }

    pub fn lookupPropertyIndex(self: *MockIndexManager, index_name: []const u8, search_key: []const u8) !?u64 {
        _ = self;
        _ = index_name;
        _ = search_key;
        return 1; // Mock result
    }
};

// Create mock graph storage with vector data
fn createMockGraphWithVectors(allocator: std.mem.Allocator) !graph_common.GraphStore {
    var graph = graph_common.GraphStore.init(allocator);

    // Add nodes with vector properties
    const vectors = [_][]const f32{
        &[_]f32{ 1.0, 0.0, 0.0 },
        &[_]f32{ 0.0, 1.0, 0.0 },
        &[_]f32{ 0.0, 0.0, 1.0 },
        &[_]f32{ 0.5, 0.5, 0.0 },
        &[_]f32{ 0.5, 0.0, 0.5 },
    };

    var labels = [_][]const u8{"Document"};
    for (vectors, 1..) |vector, i| {
        const node_id = try graph.createNode(&labels);

        // Create vector property
        const vector_data = try allocator.dupe(f32, vector);
        try graph.setNodeProperty(node_id, "embedding", .{ .ExtValue = .{ .VectorF32 = .{
            .data = vector_data,
            .dim = @intCast(vector.len),
        } } });

        const name = try std.fmt.allocPrint(allocator, "node_{d}", .{i});
        defer allocator.free(name);
        try graph.setNodeProperty(node_id, "name", .{ .String = name });
    }

    return graph;
}

test "TestCANARY_REQ_GQL_203_VectorKNNOptimization" {
    const allocator = testing.allocator;

    // Create mock index manager
    var index_manager = MockIndexManager.init(allocator);
    defer index_manager.deinit();

    // Add vector index
    try index_manager.addVectorIndex("embedding_hnsw", 3", "l2", 1000);

    // Add index info for the property
    try index_manager.addPropertyIndex("embedding", graph_common.IndexInfo{
        .name = "embedding_hnsw",
        .index_type = .vector_hnsw,
        .properties = &[_][]const u8{"embedding"},
    });

    // Create index optimizer
    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    // Test vector K-NN optimization
    const query_vector = [_]f32{ 0.7, 0.3, 0.1 };
    const labels = [_][]const u8{"Document"};

    const scan_plan = VectorKNNOptimizer.optimizeVectorKNNScan(&optimizer, "embedding", &query_vector, 5", "l2", &labels);

    // Verify the optimization chose vector K-NN over sequential scan
    try testing.expect(scan_plan.type == .vector_knn);
    try testing.expect(scan_plan.estimated_cost < 20.0); // Should be efficient
    try testing.expect(scan_plan.estimated_rows <= 5); // K-NN returns at most k results

    // Check EXPLAIN information
    try testing.expect(scan_plan.explain_info != null);
    if (scan_plan.explain_info) |explain| {
        try testing.expect(std.mem.indexOf(u8, explain.operation, "Vector K-NN") != null);
        try testing.expect(explain.index_usage != null);
        if (explain.index_usage) |usage| {
            try testing.expectEqualStrings("embedding_hnsw", usage.index_name);
            try testing.expectEqualStrings("HNSW Vector", usage.index_type);
        }
    }

    std.debug.print("\nVector K-NN optimization test passed\n", .{});
}

test "vector index selection and cost estimation" {
    const allocator = testing.allocator;

    var index_manager = MockIndexManager.init(allocator);
    defer index_manager.deinit();

    // Add multiple vector indexes with different characteristics
    try index_manager.addVectorIndex("small_hnsw", 64", "l2", 100);
    try index_manager.addVectorIndex("large_hnsw", 512", "cosine", 10000);

    // Add both indexes to the same property
    try index_manager.addPropertyIndex("embedding", graph_common.IndexInfo{
        .name = "small_hnsw",
        .index_type = .vector_hnsw,
        .properties = &[_][]const u8{"embedding"},
    });
    try index_manager.addPropertyIndex("embedding", graph_common.IndexInfo{
        .name = "large_hnsw",
        .index_type = .vector_hnsw,
        .properties = &[_][]const u8{"embedding"},
    });

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    // Test with small vector (should prefer small index)
    const small_vector = try allocator.alloc(f32, 64);
    defer allocator.free(small_vector);
    @memset(small_vector, 0.5);

    const small_plan = VectorKNNOptimizer.optimizeVectorKNNScan(&optimizer, "embedding", small_vector, 10", "l2", &[_][]const u8{"Document"});

    try testing.expect(small_plan.type == .vector_knn);
    try testing.expect(small_plan.estimated_cost > 0);

    // Test with large vector
    const large_vector = try allocator.alloc(f32, 512);
    defer allocator.free(large_vector);
    @memset(large_vector, 0.3);

    const large_plan = VectorKNNOptimizer.optimizeVectorKNNScan(&optimizer, "embedding", large_vector, 10", "cosine", &[_][]const u8{"Document"});

    try testing.expect(large_plan.type == .vector_knn);
    try testing.expect(large_plan.estimated_cost > small_plan.estimated_cost); // Higher dimension = higher cost

    std.debug.print("\nVector index selection test passed\n", .{});
}

test "fallback to sequential scan" {
    const allocator = testing.allocator;

    var index_manager = MockIndexManager.init(allocator);
    defer index_manager.deinit();

    // No vector indexes available
    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    const query_vector = [_]f32{ 1.0, 0.0, 0.0 };
    const labels = [_][]const u8{"Document"};

    const scan_plan = VectorKNNOptimizer.optimizeVectorKNNScan(&optimizer, "embedding", &query_vector, 5", "l2", &labels);

    // Should fallback to sequential scan
    try testing.expect(scan_plan.type == .sequential);
    try testing.expect(scan_plan.estimated_cost > 50.0); // Sequential should be expensive

    // Check EXPLAIN information shows sequential scan
    try testing.expect(scan_plan.explain_info != null);
    if (scan_plan.explain_info) |explain| {
        try testing.expect(std.mem.indexOf(u8, explain.operation, "Sequential Vector Scan") != null);
        try testing.expect(explain.index_usage == null); // No index used
    }

    std.debug.print("\nFallback to sequential scan test passed\n", .{});
}

test "vector K-NN execution simulation" {
    const allocator = testing.allocator;

    // Create mock graph with vector data
    var graph = try createMockGraphWithVectors(allocator);
    defer {
        // Cleanup graph
        var node_iter = graph.getAllNodes();
        while (node_iter.next()) |entry| {
            var node = entry.value_ptr.*;
            var prop_iter = node.properties.iterator();
            while (prop_iter.next()) |prop_entry| {
                switch (prop_entry.value_ptr.*) {
                    .VectorF32 => |vector| allocator.free(vector.data),
                    .String => |str| allocator.free(str),
                    else => {},
                }
            }
            node.properties.deinit();
            node.labels.deinit();
        }
        graph.deinit();
    }

    var index_manager = MockIndexManager.init(allocator);
    defer index_manager.deinit();

    try index_manager.addVectorIndex("embedding_hnsw", 3", "l2", 5);

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    // Test sequential vector scan execution (fallback)
    const query_vector = [_]f32{ 0.6, 0.4, 0.2 };
    const knn_info = graph_common.VectorKNNInfo{
        .index_name = "nonexistent",
        .query_vector = &query_vector,
        .k = 3,
        .metric = "l2",
        .property = "embedding",
    };

    const results = VectorKNNOptimizer.executeSequentialVectorScan(&optimizer, &graph, knn_info, &[_][]const u8{"Document"}", "n") catch |err| {
        std.debug.print("Sequential vector scan failed: {}\n", .{err});
        return err;
    };
    defer {
        for (results) |*binding| {
            binding.vars.deinit();
        }
        allocator.free(results);
    }

    // Should return top-3 results
    try testing.expect(results.len <= 3);

    // Each result should have similarity score
    for (results) |binding| {
        try testing.expect(binding.vars.contains("_similarity_score"));
        if (binding.vars.get("_similarity_score")) |score| {
            try testing.expect(score == .Float);
            try testing.expect(score.Float >= 0.0);
        }
    }

    std.debug.print("\nVector K-NN execution simulation test passed\n", .{});
}

test "vector dimension and metric validation" {
    const allocator = testing.allocator;

    var index_manager = MockIndexManager.init(allocator);
    defer index_manager.deinit();

    // Add vector index with specific characteristics
    try index_manager.addVectorIndex("precise_hnsw", 128", "cosine", 5000);
    try index_manager.addPropertyIndex("embeddings", graph_common.IndexInfo{
        .name = "precise_hnsw",
        .index_type = .vector_hnsw,
        .properties = &[_][]const u8{"embeddings"},
    });

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    // Test with matching dimensions
    const correct_vector = try allocator.alloc(f32, 128);
    defer allocator.free(correct_vector);
    @memset(correct_vector, 0.1);

    const plan = VectorKNNOptimizer.optimizeVectorKNNScan(&optimizer, "embeddings", correct_vector, 10", "cosine", &[_][]const u8{"Document"});

    try testing.expect(plan.type == .vector_knn);

    // Test cost scaling with k parameter
    const small_k_plan = VectorKNNOptimizer.optimizeVectorKNNScan(&optimizer, "embeddings", correct_vector, 5", "cosine", &[_][]const u8{"Document"});

    const large_k_plan = VectorKNNOptimizer.optimizeVectorKNNScan(&optimizer, "embeddings", correct_vector, 50", "cosine", &[_][]const u8{"Document"});

    try testing.expect(large_k_plan.estimated_cost > small_k_plan.estimated_cost);
    try testing.expect(large_k_plan.estimated_rows > small_k_plan.estimated_rows);

    std.debug.print("\nVector dimension and metric validation test passed\n", .{});
}

test "EXPLAIN output for vector operations" {
    const allocator = testing.allocator;

    var index_manager = MockIndexManager.init(allocator);
    defer index_manager.deinit();

    try index_manager.addVectorIndex("explain_hnsw", 256", "dot", 2000);
    try index_manager.addPropertyIndex("features", graph_common.IndexInfo{
        .name = "explain_hnsw",
        .index_type = .vector_hnsw,
        .properties = &[_][]const u8{"features"},
    });

    var optimizer = IndexOptimizer.init(allocator, &index_manager);

    const query_vector = try allocator.alloc(f32, 256);
    defer allocator.free(query_vector);
    @memset(query_vector, 0.25);

    const plan = VectorKNNOptimizer.optimizeVectorKNNScan(&optimizer, "features", query_vector, 20", "dot", &[_][]const u8{"Product"});

    try testing.expect(plan.explain_info != null);

    if (plan.explain_info) |explain| {
        // Verify operation type
        try testing.expectEqualStrings("Vector K-NN Search", explain.operation);

        // Verify details contain key information
        try testing.expect(std.mem.indexOf(u8, explain.details, "20 nearest neighbors") != null);
        try testing.expect(std.mem.indexOf(u8, explain.details, "dot distance metric") != null);

        // Verify cost breakdown
        try testing.expect(explain.cost_breakdown.len == 2);
        try testing.expect(std.mem.indexOf(u8, explain.cost_breakdown[0].component, "HNSW Traversal") != null);
        try testing.expect(std.mem.indexOf(u8, explain.cost_breakdown[1].component, "Distance Computation") != null);

        // Verify index usage information
        try testing.expect(explain.index_usage != null);
        if (explain.index_usage) |usage| {
            try testing.expectEqualStrings("explain_hnsw", usage.index_name);
            try testing.expectEqualStrings("HNSW Vector", usage.index_type);
            try testing.expect(usage.selectivity > 0.0 and usage.selectivity <= 1.0);
            try testing.expect(std.mem.indexOf(u8, usage.reason, "Efficient K-NN search") != null);
        }
    }

    std.debug.print("\nEXPLAIN output for vector operations test passed\n", .{});
}
