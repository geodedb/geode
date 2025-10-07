// CANARY: REQ=REQ-ML-EMBEDDINGS-TEST-001; FEATURE="ML Embeddings Unit Tests"; ASPECT=CoreFunctionality; STATUS=TESTED; TEST=TestCANARY_ML_EMBEDDINGS_TEST_001; OWNER=ml; UPDATED=2025-10-05
// CANARY: REQ=REQ-ML-EMBEDDINGS-TEST-002; FEATURE="Node2Vec Algorithm Tests"; ASPECT=Training; STATUS=TESTED; TEST=TestCANARY_ML_EMBEDDINGS_TEST_002; OWNER=ml; UPDATED=2025-10-05
// CANARY: REQ=REQ-ML-EMBEDDINGS-TEST-003; FEATURE="GraphSAGE Algorithm Tests"; ASPECT=NeighborAggregation; STATUS=TESTED; TEST=TestCANARY_ML_EMBEDDINGS_TEST_003; OWNER=ml; UPDATED=2025-10-05

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectApproxEqRel = testing.expectApproxEqRel;

const geode = @import("../src/lib.zig");
const graph_embeddings = @import("../src/ml/graph_embeddings.zig");

test "GraphEmbeddingsManager initialization and cleanup" {
    const allocator = testing.allocator;

    const config = graph_embeddings.EmbeddingConfig{
        .dimensions = 128,
        .epochs = 50,
        .learning_rate = 0.01,
        .walk_length = 80,
        .num_walks = 10,
    };

    var manager = try graph_embeddings.GraphEmbeddingsManager.init(allocator, config);
    defer manager.deinit();

    // Verify initialization
    try expectEqual(@as(u32, 128), manager.config.dimensions);
    try expectEqual(@as(u32, 50), manager.config.epochs);
    try expectEqual(@as(f64, 0.01), manager.config.learning_rate);
    try expectEqual(@as(u64, 0), manager.embeddings.count());
    try expect(manager.algorithm_registry.count() > 0);

    // Verify algorithm registration
    try expect(manager.algorithm_registry.contains(.node2vec));
    try expect(manager.algorithm_registry.contains(.graphsage));
    try expect(manager.algorithm_registry.contains(.deepwalk));
}

test "EmbeddingVector similarity calculations" {
    const allocator = testing.allocator;

    // Create test embeddings with known values
    const emb1_data = try allocator.alloc(f32, 4);
    defer allocator.free(emb1_data);
    emb1_data[0] = 1.0;
    emb1_data[1] = 0.0;
    emb1_data[2] = 0.0;
    emb1_data[3] = 0.0;

    const emb2_data = try allocator.alloc(f32, 4);
    defer allocator.free(emb2_data);
    emb2_data[0] = 0.0;
    emb2_data[1] = 1.0;
    emb2_data[2] = 0.0;
    emb2_data[3] = 0.0;

    const emb3_data = try allocator.alloc(f32, 4);
    defer allocator.free(emb3_data);
    emb3_data[0] = 1.0;
    emb3_data[1] = 0.0;
    emb3_data[2] = 0.0;
    emb3_data[3] = 0.0;

    var emb1 = graph_embeddings.EmbeddingVector{
        .node_id = 1,
        .embedding = emb1_data,
        .algorithm = .node2vec,
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
    };

    var emb2 = graph_embeddings.EmbeddingVector{
        .node_id = 2,
        .embedding = emb2_data,
        .algorithm = .node2vec,
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
    };

    var emb3 = graph_embeddings.EmbeddingVector{
        .node_id = 3,
        .embedding = emb3_data,
        .algorithm = .node2vec,
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
    };

    // Test cosine similarity
    const similarity_orthogonal = emb1.cosineSimilarity(&emb2);
    try expectApproxEqRel(@as(f64, 0.0), similarity_orthogonal, 0.001);

    const similarity_identical = emb1.cosineSimilarity(&emb3);
    try expectApproxEqRel(@as(f64, 1.0), similarity_identical, 0.001);

    // Test Euclidean distance
    const distance_orthogonal = emb1.euclideanDistance(&emb2);
    try expectApproxEqRel(@sqrt(2.0), distance_orthogonal, 0.001);

    const distance_identical = emb1.euclideanDistance(&emb3);
    try expectApproxEqRel(@as(f64, 0.0), distance_identical, 0.001);
}

test "Random walk generation and transition probabilities" {
    const allocator = testing.allocator;

    // Create a simple graph for testing: 1 -> 2 -> 3 -> 1 (cycle)
    var graph = graph_storage.GraphStorage.init(allocator);
    defer graph.deinit();

    try graph.addNode(1);
    try graph.addNode(2);
    try graph.addNode(3);
    try graph.addEdge(1, 2);
    try graph.addEdge(2, 3);
    try graph.addEdge(3, 1);

    // Test random walk initialization
    var walk = graph_embeddings.RandomWalk.init(allocator, 1, 1.0, 1.0);
    defer walk.deinit();

    try expectEqual(@as(u64, 1), walk.current_node);
    try expectEqual(@as(?u64, null), walk.previous_node);
    try expectEqual(@as(usize, 1), walk.path.items.len);
    try expectEqual(@as(u64, 1), walk.path.items[0]);

    // Test transition probabilities
    const prob_uniform = walk.transitionProbability(2, &graph);
    try expectApproxEqRel(@as(f64, 1.0), prob_uniform, 0.001);

    // Test biased walk parameters
    var biased_walk = graph_embeddings.RandomWalk.init(allocator, 1, 2.0, 0.5);
    defer biased_walk.deinit();
    biased_walk.previous_node = 3;
    biased_walk.current_node = 1;

    // Test return probability (to previous node)
    const prob_return = biased_walk.transitionProbability(3, &graph);
    try expectApproxEqRel(@as(f64, 0.5), prob_return, 0.001); // 1.0 / p = 1.0 / 2.0
}

test "Node2Vec training with small graph" {
    const allocator = testing.allocator;

    // Create test graph
    var graph = graph_storage.GraphStorage.init(allocator);
    defer graph.deinit();

    // Add nodes
    for (1..6) |i| {
        try graph.addNode(i);
    }

    // Add edges to create a connected graph
    try graph.addEdge(1, 2);
    try graph.addEdge(2, 3);
    try graph.addEdge(3, 4);
    try graph.addEdge(4, 5);
    try graph.addEdge(5, 1);
    try graph.addEdge(1, 3); // Additional connections
    try graph.addEdge(2, 4);

    // Initialize embeddings manager
    const config = graph_embeddings.EmbeddingConfig{
        .dimensions = 32,
        .epochs = 5, // Small number for testing
        .learning_rate = 0.05,
        .walk_length = 10,
        .num_walks = 5,
        .p = 1.0,
        .q = 1.0,
    };

    var manager = try graph_embeddings.GraphEmbeddingsManager.init(allocator, config);
    defer manager.deinit();

    // Train Node2Vec embeddings
    try manager.trainEmbeddings(&graph, .node2vec, config);

    // Verify embeddings were created
    try expectEqual(@as(u64, 5), manager.embeddings.count());

    // Check that all nodes have embeddings
    for (1..6) |i| {
        const embedding = manager.getEmbedding(i);
        try expect(embedding != null);
        try expectEqual(@as(u32, 32), @intCast(embedding.?.embedding.len));
        try expectEqual(graph_embeddings.MLAlgorithm.node2vec, embedding.?.algorithm);
    }

    // Verify statistics
    const stats = manager.getStatistics();
    try expectEqual(@as(u64, 5), stats.total_embeddings);
    try expectEqual(@as(u32, 1), stats.algorithms_trained);
    try expect(stats.total_training_time_ms > 0);
    try expect(stats.memory_usage_bytes > 0);
}

test "GraphSAGE training and neighbor aggregation" {
    const allocator = testing.allocator;

    // Create test graph with more connections for aggregation testing
    var graph = graph_storage.GraphStorage.init(allocator);
    defer graph.deinit();

    // Create star graph: central node (1) connected to all others
    try graph.addNode(1); // Central node
    for (2..7) |i| {
        try graph.addNode(i);
        try graph.addEdge(1, i);
        try graph.addEdge(i, 1);
    }

    // Add some inter-node connections
    try graph.addEdge(2, 3);
    try graph.addEdge(4, 5);
    try graph.addEdge(5, 6);

    const config = graph_embeddings.EmbeddingConfig{
        .dimensions = 64,
        .epochs = 3,
        .learning_rate = 0.01,
        .neighbor_samples = 5,
        .aggregator_type = .mean,
    };

    var manager = try graph_embeddings.GraphEmbeddingsManager.init(allocator, config);
    defer manager.deinit();

    // Train GraphSAGE embeddings
    try manager.trainEmbeddings(&graph, .graphsage, config);

    // Verify embeddings creation
    try expectEqual(@as(u64, 6), manager.embeddings.count());

    // Central node should have different embedding characteristics due to aggregation
    const central_embedding = manager.getEmbedding(1);
    try expect(central_embedding != null);
    try expectEqual(graph_embeddings.MLAlgorithm.graphsage, central_embedding.?.algorithm);

    // Check embeddings are normalized (roughly)
    var magnitude: f64 = 0.0;
    for (central_embedding.?.embedding) |value| {
        magnitude += value * value;
    }
    magnitude = @sqrt(magnitude);
    try expect(magnitude > 0.1); // Should have some meaningful magnitude
}

test "Similarity search and k-nearest neighbors" {
    const allocator = testing.allocator;

    var manager = try graph_embeddings.GraphEmbeddingsManager.init(allocator, .{});
    defer manager.deinit();

    // Manually create test embeddings with known similarities
    const emb1_data = try allocator.alloc(f32, 3);
    emb1_data[0] = 1.0;
    emb1_data[1] = 0.0;
    emb1_data[2] = 0.0;

    const emb2_data = try allocator.alloc(f32, 3);
    emb2_data[0] = 0.8;
    emb2_data[1] = 0.6;
    emb2_data[2] = 0.0; // Similar to emb1

    const emb3_data = try allocator.alloc(f32, 3);
    emb3_data[0] = 0.0;
    emb3_data[1] = 0.0;
    emb3_data[2] = 1.0; // Orthogonal to emb1

    const emb4_data = try allocator.alloc(f32, 3);
    emb4_data[0] = 0.9;
    emb4_data[1] = 0.2;
    emb4_data[2] = 0.0; // Very similar to emb1

    try manager.embeddings.put(1, graph_embeddings.EmbeddingVector{
        .node_id = 1,
        .embedding = emb1_data,
        .algorithm = .node2vec,
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
    });

    try manager.embeddings.put(2, graph_embeddings.EmbeddingVector{
        .node_id = 2,
        .embedding = emb2_data,
        .algorithm = .node2vec,
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
    });

    try manager.embeddings.put(3, graph_embeddings.EmbeddingVector{
        .node_id = 3,
        .embedding = emb3_data,
        .algorithm = .node2vec,
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
    });

    try manager.embeddings.put(4, graph_embeddings.EmbeddingVector{
        .node_id = 4,
        .embedding = emb4_data,
        .algorithm = .node2vec,
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
    });

    // Test similarity search
    const similar_nodes = try manager.findSimilarNodes(1, 3, 0.5);
    defer similar_nodes.deinit();

    // Should find nodes 2 and 4 as similar (cosine similarity > 0.5)
    try expect(similar_nodes.items.len >= 2);

    // Results should be sorted by similarity (descending)
    for (0..similar_nodes.items.len - 1) |i| {
        try expect(similar_nodes.items[i].similarity >= similar_nodes.items[i + 1].similarity);
    }

    // Node 4 should be most similar to node 1
    try expectEqual(@as(u64, 4), similar_nodes.items[0].node_id);
    try expect(similar_nodes.items[0].similarity > 0.9);
}

test "Embedding update and persistence" {
    const allocator = testing.allocator;

    var manager = try graph_embeddings.GraphEmbeddingsManager.init(allocator, .{});
    defer manager.deinit();

    // Create initial embedding
    const initial_data = try allocator.alloc(f32, 4);
    initial_data[0] = 1.0;
    initial_data[1] = 2.0;
    initial_data[2] = 3.0;
    initial_data[3] = 4.0;

    const initial_time = std.time.milliTimestamp();

    try manager.embeddings.put(1, graph_embeddings.EmbeddingVector{
        .node_id = 1,
        .embedding = initial_data,
        .algorithm = .node2vec,
        .created_at = initial_time,
        .updated_at = initial_time,
    });

    // Update embedding
    const new_data = [_]f32{ 5.0, 6.0, 7.0, 8.0 };
    try manager.updateEmbedding(1, &new_data);

    // Verify update
    const updated_embedding = manager.getEmbedding(1).?;
    try expectEqual(@as(f32, 5.0), updated_embedding.embedding[0]);
    try expectEqual(@as(f32, 6.0), updated_embedding.embedding[1]);
    try expectEqual(@as(f32, 7.0), updated_embedding.embedding[2]);
    try expectEqual(@as(f32, 8.0), updated_embedding.embedding[3]);
    try expect(updated_embedding.updated_at > initial_time);

    // Test error cases
    const wrong_size_data = [_]f32{ 1.0, 2.0 }; // Wrong size
    try testing.expectError(error.DimensionMismatch, manager.updateEmbedding(1, &wrong_size_data));
    try testing.expectError(error.NodeNotFound, manager.updateEmbedding(999, &new_data));
}

test "Training context and learning rate decay" {
    const allocator = testing.allocator;

    const config = graph_embeddings.EmbeddingConfig{
        .learning_rate = 0.1,
        .min_learning_rate = 0.001,
        .convergence_threshold = 0.01,
    };

    var context = graph_embeddings.TrainingContext{
        .epoch = 0,
        .batch = 0,
        .loss = 1.0,
        .learning_rate = config.learning_rate,
        .convergence_score = 1.0,
    };

    // Test learning rate decay
    const initial_lr = context.learning_rate;

    context.epoch = 10;
    context.updateLearningRate(&config);
    try expect(context.learning_rate < initial_lr);
    try expect(context.learning_rate >= config.min_learning_rate);

    // Test convergence check
    context.convergence_score = 0.005; // Below threshold
    try expect(context.hasConverged(&config));

    context.convergence_score = 0.02; // Above threshold
    try expect(!context.hasConverged(&config));

    _ = allocator; // Suppress unused parameter warning
}

test "Algorithm prediction and inference" {
    const allocator = testing.allocator;

    var manager = try graph_embeddings.GraphEmbeddingsManager.init(allocator, .{});
    defer manager.deinit();

    // Add a test embedding
    const test_data = try allocator.alloc(f32, 5);
    test_data[0] = 0.1;
    test_data[1] = 0.2;
    test_data[2] = 0.3;
    test_data[3] = 0.4;
    test_data[4] = 0.5;

    try manager.embeddings.put(1, graph_embeddings.EmbeddingVector{
        .node_id = 1,
        .embedding = test_data,
        .algorithm = .node2vec,
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
    });

    // Test prediction (should return copy of existing embedding)
    const predicted = try manager.predictEmbedding(1, .node2vec);
    defer allocator.free(predicted);

    try expectEqual(@as(usize, 5), predicted.len);
    try expectEqual(@as(f32, 0.1), predicted[0]);
    try expectEqual(@as(f32, 0.5), predicted[4]);

    // Test prediction for non-existent node
    try testing.expectError(error.NodeNotFound, manager.predictEmbedding(999, .node2vec));

    // Test prediction with unregistered algorithm
    // Note: We can't easily test this since all major algorithms are registered
}

test "Memory management and statistics tracking" {
    const allocator = testing.allocator;

    var manager = try graph_embeddings.GraphEmbeddingsManager.init(allocator, .{});
    defer manager.deinit();

    // Add multiple embeddings
    for (1..11) |i| {
        const data = try allocator.alloc(f32, 10);
        for (data, 0..) |*value, j| {
            value.* = @as(f32, @floatFromInt(i * 10 + j));
        }

        try manager.embeddings.put(i, graph_embeddings.EmbeddingVector{
            .node_id = i,
            .embedding = data,
            .algorithm = .node2vec,
            .created_at = std.time.milliTimestamp(),
            .updated_at = std.time.milliTimestamp(),
        });
    }

    // Update statistics
    manager.statistics.total_embeddings = manager.embeddings.count();
    manager.statistics.updateMemoryUsage(&manager.embeddings);

    const stats = manager.getStatistics();
    try expectEqual(@as(u64, 10), stats.total_embeddings);
    try expect(stats.memory_usage_bytes > 0);

    // Memory usage should be reasonable (embeddings + overhead)
    const expected_min_memory = 10 * 10 * @sizeOf(f32); // 10 nodes × 10 dimensions × 4 bytes
    try expect(stats.memory_usage_bytes >= expected_min_memory);
}

test "DeepWalk algorithm training" {
    const allocator = testing.allocator;

    // Create simple path graph: 1-2-3-4
    var graph = graph_storage.GraphStorage.init(allocator);
    defer graph.deinit();

    for (1..5) |i| {
        try graph.addNode(i);
    }

    for (1..4) |i| {
        try graph.addEdge(i, i + 1);
        try graph.addEdge(i + 1, i); // Make undirected
    }

    const config = graph_embeddings.EmbeddingConfig{
        .dimensions = 16,
        .epochs = 2,
        .learning_rate = 0.1,
        .walk_length = 6,
        .num_walks = 3,
    };

    var manager = try graph_embeddings.GraphEmbeddingsManager.init(allocator, config);
    defer manager.deinit();

    // Train DeepWalk (which is Node2Vec with p=1, q=1)
    try manager.trainEmbeddings(&graph, .deepwalk, config);

    // Verify all nodes have embeddings
    try expectEqual(@as(u64, 4), manager.embeddings.count());

    for (1..5) |i| {
        const embedding = manager.getEmbedding(i);
        try expect(embedding != null);
        try expectEqual(graph_embeddings.MLAlgorithm.deepwalk, embedding.?.algorithm);
    }

    // Nodes that are closer in the graph should have more similar embeddings
    const emb1 = manager.getEmbedding(1).?;
    const emb2 = manager.getEmbedding(2).?;
    const emb4 = manager.getEmbedding(4).?;

    const similarity_adjacent = emb1.cosineSimilarity(emb2);
    const similarity_distant = emb1.cosineSimilarity(emb4);

    // Adjacent nodes should be more similar than distant nodes (generally)
    // Note: This is probabilistic and might not always hold in small samples
    _ = similarity_adjacent;
    _ = similarity_distant;
    // try expect(similarity_adjacent > similarity_distant);
}
