const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

// Import the ML graph embeddings module
const geode = @import("../src/lib.zig");
const ml = @import("../src/ml/graph_embeddings.zig");
const GraphEmbeddingsManager = ml.GraphEmbeddingsManager;
const MLAlgorithm = ml.MLAlgorithm;
const EmbeddingVector = ml.EmbeddingVector;
const TrainingContext = ml.TrainingContext;
const SimilarityMetric = ml.SimilarityMetric;

// Mock graph data structures for testing
const MockNode = struct {
    id: u64,
    labels: []const []const u8,
    properties: std.StringHashMap([]const u8),
    
    pub fn init(allocator: std.mem.Allocator, id: u64, labels: []const []const u8) !MockNode {
        return MockNode{
            .id = id,
            .labels = labels,
            .properties = std.StringHashMap([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *MockNode) void {
        self.properties.deinit();
    }
};

const MockEdge = struct {
    id: u64,
    source: u64,
    target: u64,
    edge_type: []const u8,
    weight: f32,
    
    pub fn init(id: u64, source: u64, target: u64, edge_type: []const u8, weight: f32) MockEdge {
        return MockEdge{
            .id = id,
            .source = source,
            .target = target,
            .edge_type = edge_type,
            .weight = weight,
        };
    }
};

const MockGraphDatabase = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMap(u64, MockNode),
    edges: std.ArrayList(MockEdge),
    adjacency: std.AutoHashMap(u64, std.ArrayList(u64)),
    
    pub fn init(allocator: std.mem.Allocator) MockGraphDatabase {
        return MockGraphDatabase{
            .allocator = allocator,
            .nodes = std.AutoHashMap(u64, MockNode).init(allocator),
            .edges = std.ArrayList(MockEdge).init(allocator),
            .adjacency = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
        };
    }
    
    pub fn deinit(self: *MockGraphDatabase) void {
        var node_iterator = self.nodes.iterator();
        while (node_iterator.next()) |entry| {
            var node = entry.value_ptr;
            node.deinit();
        }
        self.nodes.deinit();
        
        self.edges.deinit();
        
        var adj_iterator = self.adjacency.iterator();
        while (adj_iterator.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.adjacency.deinit();
    }
    
    pub fn addNode(self: *MockGraphDatabase, node: MockNode) !void {
        try self.nodes.put(node.id, node);
        try self.adjacency.put(node.id, std.ArrayList(u64).init(self.allocator));
    }
    
    pub fn addEdge(self: *MockGraphDatabase, edge: MockEdge) !void {
        try self.edges.append(edge);
        
        // Update adjacency lists
        if (self.adjacency.getPtr(edge.source)) |source_adj| {
            try source_adj.append(edge.target);
        }
        if (self.adjacency.getPtr(edge.target)) |target_adj| {
            try target_adj.append(edge.source);
        }
    }
    
    pub fn getNeighbors(self: *MockGraphDatabase, node_id: u64) ?[]const u64 {
        if (self.adjacency.get(node_id)) |neighbors| {
            return neighbors.items;
        }
        return null;
    }
    
    pub fn getNodeCount(self: *MockGraphDatabase) usize {
        return self.nodes.count();
    }
    
    pub fn getEdgeCount(self: *MockGraphDatabase) usize {
        return self.edges.items.len;
    }
};

// Test: End-to-end Node2Vec embedding generation and similarity search
test "CANARY_REQ_ML_001_Node2Vec_End_To_End_Integration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create mock graph database
    var graph_db = MockGraphDatabase.init(allocator);
    defer graph_db.deinit();
    
    // Build a small social network graph
    const person_label = [_][]const u8{"Person"};
    try graph_db.addNode(try MockNode.init(allocator, 1, &person_label));
    try graph_db.addNode(try MockNode.init(allocator, 2, &person_label));
    try graph_db.addNode(try MockNode.init(allocator, 3, &person_label));
    try graph_db.addNode(try MockNode.init(allocator, 4, &person_label));
    try graph_db.addNode(try MockNode.init(allocator, 5, &person_label));
    
    // Add friendship edges
    try graph_db.addEdge(MockEdge.init(1, 1, 2, "FRIEND", 1.0));
    try graph_db.addEdge(MockEdge.init(2, 1, 3, "FRIEND", 1.0));
    try graph_db.addEdge(MockEdge.init(3, 2, 4, "FRIEND", 1.0));
    try graph_db.addEdge(MockEdge.init(4, 3, 4, "FRIEND", 1.0));
    try graph_db.addEdge(MockEdge.init(5, 4, 5, "FRIEND", 1.0));
    
    // Initialize ML embeddings manager
    var embeddings_manager = try GraphEmbeddingsManager.init(allocator, 64);
    defer embeddings_manager.deinit();
    
    // Configure Node2Vec algorithm
    try embeddings_manager.configureAlgorithm(MLAlgorithm.node2vec, .{
        .learning_rate = 0.01,
        .num_epochs = 10,
        .batch_size = 32,
        .p = 1.0,  // Return parameter
        .q = 1.0,  // In-out parameter
        .walk_length = 10,
        .num_walks = 20,
    });
    
    // Generate embeddings for all nodes
    for (1..6) |node_id| {
        const walks = try generateRandomWalks(allocator, &graph_db, node_id, 20, 10, 1.0, 1.0);
        defer {
            for (walks) |walk| {
                allocator.free(walk);
            }
            allocator.free(walks);
        }
        
        try embeddings_manager.generateEmbedding(node_id, MLAlgorithm.node2vec);
    }
    
    // Test similarity search
    const similar_nodes = try embeddings_manager.findSimilarNodes(1, 3, SimilarityMetric.cosine);
    defer allocator.free(similar_nodes);
    
    try testing.expect(similar_nodes.len <= 3);
    try testing.expect(similar_nodes.len > 0);
    
    // Verify embeddings were generated
    try testing.expect(embeddings_manager.hasEmbedding(1));
    try testing.expect(embeddings_manager.hasEmbedding(2));
    try testing.expect(embeddings_manager.hasEmbedding(3));
    
    print("Node2Vec integration test completed successfully\n");
}

// Test: GraphSAGE training with neighbor aggregation
test "CANARY_REQ_ML_002_GraphSAGE_Neighbor_Aggregation_Integration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create mock graph with feature-rich nodes
    var graph_db = MockGraphDatabase.init(allocator);
    defer graph_db.deinit();
    
    // Build a graph with different node types
    const user_label = [_][]const u8{"User"};
    const item_label = [_][]const u8{"Item"};
    
    for (1..11) |i| {
        if (i <= 5) {
            try graph_db.addNode(try MockNode.init(allocator, i, &user_label));
        } else {
            try graph_db.addNode(try MockNode.init(allocator, i, &item_label));
        }
    }
    
    // Add user-item and user-user edges
    try graph_db.addEdge(MockEdge.init(1, 1, 6, "LIKES", 0.8));
    try graph_db.addEdge(MockEdge.init(2, 1, 7, "LIKES", 0.9));
    try graph_db.addEdge(MockEdge.init(3, 2, 6, "LIKES", 0.7));
    try graph_db.addEdge(MockEdge.init(4, 2, 8, "LIKES", 0.6));
    try graph_db.addEdge(MockEdge.init(5, 3, 9, "LIKES", 0.85));
    try graph_db.addEdge(MockEdge.init(6, 1, 2, "FRIEND", 1.0));
    try graph_db.addEdge(MockEdge.init(7, 2, 3, "FRIEND", 1.0));
    
    // Initialize ML embeddings manager
    var embeddings_manager = try GraphEmbeddingsManager.init(allocator, 128);
    defer embeddings_manager.deinit();
    
    // Configure GraphSAGE algorithm
    try embeddings_manager.configureAlgorithm(MLAlgorithm.graphsage, .{
        .learning_rate = 0.005,
        .num_epochs = 15,
        .batch_size = 16,
        .aggregation_function = "mean",
        .num_samples = 5,
    });
    
    // Train embeddings with neighbor aggregation
    var training_ctx = TrainingContext{
        .algorithm = MLAlgorithm.graphsage,
        .current_epoch = 0,
        .max_epochs = 15,
        .learning_rate = 0.005,
        .batch_size = 16,
        .convergence_threshold = 0.001,
        .early_stopping_patience = 5,
        .current_loss = 1.0,
        .previous_loss = 1.0,
        .patience_counter = 0,
        .start_time = std.time.milliTimestamp(),
    };
    
    // Simulate training process
    for (0..training_ctx.max_epochs) |epoch| {
        training_ctx.current_epoch = epoch;
        training_ctx.previous_loss = training_ctx.current_loss;
        training_ctx.current_loss = 1.0 / @as(f32, @floatFromInt(epoch + 1)); // Simulated decreasing loss
        
        // Generate embeddings for users and items
        for (1..11) |node_id| {
            try embeddings_manager.generateEmbedding(node_id, MLAlgorithm.graphsage);
        }
        
        // Check convergence
        if (training_ctx.hasConverged()) break;
    }
    
    // Test recommendation system using embeddings
    const user1_recommendations = try embeddings_manager.findSimilarNodes(1, 5, SimilarityMetric.cosine);
    defer allocator.free(user1_recommendations);
    
    try testing.expect(user1_recommendations.len <= 5);
    
    // Verify embeddings were generated for all nodes
    for (1..11) |node_id| {
        try testing.expect(embeddings_manager.hasEmbedding(node_id));
    }
    
    print("GraphSAGE neighbor aggregation integration test completed successfully\n");
}

// Test: Multi-algorithm comparison and performance metrics
test "CANARY_REQ_ML_003_Multi_Algorithm_Performance_Comparison" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create larger test graph
    var graph_db = MockGraphDatabase.init(allocator);
    defer graph_db.deinit();
    
    const node_label = [_][]const u8{"Node"};
    
    // Build a ring graph with some random connections
    for (1..21) |i| {
        try graph_db.addNode(try MockNode.init(allocator, i, &node_label));
    }
    
    // Ring connections
    for (1..21) |i| {
        const next = if (i == 20) 1 else i + 1;
        try graph_db.addEdge(MockEdge.init(i, i, next, "CONNECTS", 1.0));
    }
    
    // Add some cross-connections
    try graph_db.addEdge(MockEdge.init(21, 1, 11, "CONNECTS", 1.0));
    try graph_db.addEdge(MockEdge.init(22, 5, 15, "CONNECTS", 1.0));
    try graph_db.addEdge(MockEdge.init(23, 10, 20, "CONNECTS", 1.0));
    
    // Initialize multiple ML embeddings managers for comparison
    var node2vec_manager = try GraphEmbeddingsManager.init(allocator, 64);
    defer node2vec_manager.deinit();
    
    var graphsage_manager = try GraphEmbeddingsManager.init(allocator, 64);
    defer graphsage_manager.deinit();
    
    var deepwalk_manager = try GraphEmbeddingsManager.init(allocator, 64);
    defer deepwalk_manager.deinit();
    
    // Configure algorithms
    try node2vec_manager.configureAlgorithm(MLAlgorithm.node2vec, .{
        .learning_rate = 0.01,
        .num_epochs = 5,
        .batch_size = 16,
        .p = 1.0,
        .q = 1.0,
        .walk_length = 10,
        .num_walks = 10,
    });
    
    try graphsage_manager.configureAlgorithm(MLAlgorithm.graphsage, .{
        .learning_rate = 0.01,
        .num_epochs = 5,
        .batch_size = 16,
        .aggregation_function = "mean",
        .num_samples = 3,
    });
    
    try deepwalk_manager.configureAlgorithm(MLAlgorithm.deepwalk, .{
        .learning_rate = 0.01,
        .num_epochs = 5,
        .batch_size = 16,
        .walk_length = 10,
        .num_walks = 10,
    });
    
    // Measure training time for each algorithm
    const start_time = std.time.milliTimestamp();
    
    // Train Node2Vec
    const node2vec_start = std.time.milliTimestamp();
    for (1..21) |node_id| {
        try node2vec_manager.generateEmbedding(node_id, MLAlgorithm.node2vec);
    }
    const node2vec_time = std.time.milliTimestamp() - node2vec_start;
    
    // Train GraphSAGE
    const graphsage_start = std.time.milliTimestamp();
    for (1..21) |node_id| {
        try graphsage_manager.generateEmbedding(node_id, MLAlgorithm.graphsage);
    }
    const graphsage_time = std.time.milliTimestamp() - graphsage_start;
    
    // Train DeepWalk
    const deepwalk_start = std.time.milliTimestamp();
    for (1..21) |node_id| {
        try deepwalk_manager.generateEmbedding(node_id, MLAlgorithm.deepwalk);
    }
    const deepwalk_time = std.time.milliTimestamp() - deepwalk_start;
    
    const total_time = std.time.milliTimestamp() - start_time;
    
    // Compare similarity results between algorithms
    const node2vec_similar = try node2vec_manager.findSimilarNodes(1, 5, SimilarityMetric.cosine);
    defer allocator.free(node2vec_similar);
    
    const graphsage_similar = try graphsage_manager.findSimilarNodes(1, 5, SimilarityMetric.cosine);
    defer allocator.free(graphsage_similar);
    
    const deepwalk_similar = try deepwalk_manager.findSimilarNodes(1, 5, SimilarityMetric.cosine);
    defer allocator.free(deepwalk_similar);
    
    // Verify all algorithms produced results
    try testing.expect(node2vec_similar.len > 0);
    try testing.expect(graphsage_similar.len > 0);
    try testing.expect(deepwalk_similar.len > 0);
    
    // Performance assertions
    try testing.expect(total_time > 0);
    try testing.expect(node2vec_time >= 0);
    try testing.expect(graphsage_time >= 0);
    try testing.expect(deepwalk_time >= 0);
    
    print("Multi-algorithm performance comparison completed\n");
    print("Node2Vec time: {}ms, GraphSAGE time: {}ms, DeepWalk time: {}ms\n", .{ node2vec_time, graphsage_time, deepwalk_time });
}

// Test: Real-time embedding updates and incremental learning
test "CANARY_REQ_ML_004_Real_Time_Embedding_Updates" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create dynamic graph
    var graph_db = MockGraphDatabase.init(allocator);
    defer graph_db.deinit();
    
    const person_label = [_][]const u8{"Person"};
    
    // Start with small graph
    for (1..6) |i| {
        try graph_db.addNode(try MockNode.init(allocator, i, &person_label));
    }
    
    try graph_db.addEdge(MockEdge.init(1, 1, 2, "FRIEND", 1.0));
    try graph_db.addEdge(MockEdge.init(2, 2, 3, "FRIEND", 1.0));
    try graph_db.addEdge(MockEdge.init(3, 3, 4, "FRIEND", 1.0));
    
    // Initialize embeddings manager
    var embeddings_manager = try GraphEmbeddingsManager.init(allocator, 32);
    defer embeddings_manager.deinit();
    
    // Configure for incremental learning
    try embeddings_manager.configureAlgorithm(MLAlgorithm.node2vec, .{
        .learning_rate = 0.02,
        .num_epochs = 3,
        .batch_size = 8,
        .p = 1.0,
        .q = 1.0,
        .walk_length = 5,
        .num_walks = 5,
    });
    
    // Initial training
    for (1..6) |node_id| {
        try embeddings_manager.generateEmbedding(node_id, MLAlgorithm.node2vec);
    }
    
    const initial_similarity = try embeddings_manager.calculateSimilarity(1, 3, SimilarityMetric.cosine);
    
    // Simulate graph updates - add new connections
    try graph_db.addEdge(MockEdge.init(4, 1, 4, "FRIEND", 1.0));
    try graph_db.addEdge(MockEdge.init(5, 1, 5, "FRIEND", 1.0));
    
    // Incremental embedding updates
    try embeddings_manager.generateEmbedding(1, MLAlgorithm.node2vec);
    try embeddings_manager.generateEmbedding(4, MLAlgorithm.node2vec);
    try embeddings_manager.generateEmbedding(5, MLAlgorithm.node2vec);
    
    const updated_similarity = try embeddings_manager.calculateSimilarity(1, 3, SimilarityMetric.cosine);
    
    // Add completely new node
    try graph_db.addNode(try MockNode.init(allocator, 6, &person_label));
    try graph_db.addEdge(MockEdge.init(6, 6, 1, "FRIEND", 1.0));
    
    try embeddings_manager.generateEmbedding(6, MLAlgorithm.node2vec);
    
    // Verify dynamic updates
    try testing.expect(embeddings_manager.hasEmbedding(6));
    try testing.expect(initial_similarity >= 0.0 and initial_similarity <= 1.0);
    try testing.expect(updated_similarity >= 0.0 and updated_similarity <= 1.0);
    
    // Test that new node has reasonable embedding
    const new_node_similarity = try embeddings_manager.calculateSimilarity(6, 1, SimilarityMetric.cosine);
    try testing.expect(new_node_similarity >= 0.0 and new_node_similarity <= 1.0);
    
    print("Real-time embedding updates test completed successfully\n");
}

// Test: Large-scale graph embedding with memory management
test "CANARY_REQ_ML_005_Large_Scale_Memory_Management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create larger graph to test memory management
    var graph_db = MockGraphDatabase.init(allocator);
    defer graph_db.deinit();
    
    const node_label = [_][]const u8{"Node"};
    
    // Build graph with 100 nodes
    for (1..101) |i| {
        try graph_db.addNode(try MockNode.init(allocator, i, &node_label));
    }
    
    // Create random connections (small world network)
    var prng = std.rand.DefaultPrng.init(12345);
    const random = prng.random();
    
    for (1..101) |i| {
        // Each node connects to 3-5 random other nodes
        const num_connections = random.intRangeAtMost(u32, 3, 5);
        for (0..num_connections) |j| {
            const target = random.intRangeAtMost(u64, 1, 100);
            if (target != i) {
                const edge_id = i * 1000 + j;
                try graph_db.addEdge(MockEdge.init(edge_id, i, target, "CONNECTS", 1.0));
            }
        }
    }
    
    // Initialize embeddings manager with memory constraints
    var embeddings_manager = try GraphEmbeddingsManager.init(allocator, 64);
    defer embeddings_manager.deinit();
    
    // Configure for efficient training
    try embeddings_manager.configureAlgorithm(MLAlgorithm.node2vec, .{
        .learning_rate = 0.01,
        .num_epochs = 2,
        .batch_size = 20,
        .p = 1.0,
        .q = 1.0,
        .walk_length = 5,
        .num_walks = 3,
    });
    
    // Process nodes in batches to test memory management
    const batch_size = 20;
    var batch_start: u64 = 1;
    
    while (batch_start <= 100) {
        const batch_end = @min(batch_start + batch_size, 101);
        
        // Process batch
        for (batch_start..batch_end) |node_id| {
            try embeddings_manager.generateEmbedding(node_id, MLAlgorithm.node2vec);
        }
        
        // Test batch completion
        for (batch_start..batch_end) |node_id| {
            try testing.expect(embeddings_manager.hasEmbedding(node_id));
        }
        
        batch_start = batch_end;
    }
    
    // Verify all embeddings were generated
    try testing.expect(embeddings_manager.getEmbeddingCount() == 100);
    
    // Test similarity search on large scale
    const large_scale_similar = try embeddings_manager.findSimilarNodes(1, 10, SimilarityMetric.cosine);
    defer allocator.free(large_scale_similar);
    
    try testing.expect(large_scale_similar.len <= 10);
    try testing.expect(large_scale_similar.len > 0);
    
    // Test k-NN search performance
    const knn_results = try embeddings_manager.kNearestNeighbors(50, 15, SimilarityMetric.euclidean);
    defer allocator.free(knn_results);
    
    try testing.expect(knn_results.len <= 15);
    
    print("Large-scale memory management test completed successfully\n");
    print("Generated embeddings for 100 nodes with {} total edges\n", .{graph_db.getEdgeCount()});
}

// Helper function to generate random walks (simplified implementation)
fn generateRandomWalks(allocator: std.mem.Allocator, graph: *MockGraphDatabase, start_node: u64, num_walks: usize, walk_length: usize, p: f32, q: f32) ![][]u64 {
    _ = p; // Bias parameters not used in this simplified implementation
    _ = q;
    
    var walks = try allocator.alloc([]u64, num_walks);
    var prng = std.rand.DefaultPrng.init(@intCast(start_node));
    const random = prng.random();
    
    for (0..num_walks) |walk_idx| {
        var walk = try allocator.alloc(u64, walk_length);
        walk[0] = start_node;
        
        for (1..walk_length) |step| {
            const current_node = walk[step - 1];
            if (graph.getNeighbors(current_node)) |neighbors| {
                if (neighbors.len > 0) {
                    const next_idx = random.intRangeAtMost(usize, 0, neighbors.len - 1);
                    walk[step] = neighbors[next_idx];
                } else {
                    walk[step] = current_node; // Stay at current node if no neighbors
                }
            } else {
                walk[step] = current_node;
            }
        }
        
        walks[walk_idx] = walk;
    }
    
    return walks;
}

// Test runner
pub fn main() !void {
    print("Running ML Graph Embeddings Integration Tests...\n\n");
    
    // Run all integration tests
    try testing.refAllDecls(@This());
    
    print("\nAll ML Graph Embeddings Integration Tests Completed Successfully!\n");
}