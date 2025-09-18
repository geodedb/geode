const std = @import("std");
const testing = std.testing;
const ml = @import("../src/ml/integration_enhanced.zig");

test "Node2Vec embedding generation" {
    const allocator = testing.allocator;
    
    // Create a test graph
    var graph = ml.GraphData{
        .nodes = std.AutoHashMap(ml.NodeId, void).init(allocator),
        .edges = std.AutoHashMap(ml.EdgeId, ml.GraphData.Edge).init(allocator),
        .outgoing_edges = std.AutoHashMap(ml.NodeId, std.ArrayList(ml.EdgeId)).init(allocator),
        .incoming_edges = std.AutoHashMap(ml.NodeId, std.ArrayList(ml.EdgeId)).init(allocator),
    };
    defer {
        graph.nodes.deinit();
        graph.edges.deinit();
        
        var out_it = graph.outgoing_edges.iterator();
        while (out_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        graph.outgoing_edges.deinit();
        
        var in_it = graph.incoming_edges.iterator();
        while (in_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        graph.incoming_edges.deinit();
    }
    
    // Add nodes
    for (1..11) |i| {
        try graph.nodes.put(i, {});
    }
    
    // Add edges to create a connected graph
    var edge_id: ml.EdgeId = 1;
    const edges = [_][2]ml.NodeId{
        .{ 1, 2 }, .{ 2, 3 }, .{ 3, 4 }, .{ 4, 5 },
        .{ 5, 6 }, .{ 6, 7 }, .{ 7, 8 }, .{ 8, 9 },
        .{ 9, 10 }, .{ 10, 1 }, // Create a cycle
        .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 }, .{ 4, 8 }, // Cross edges
    };
    
    for (edges) |edge| {
        try graph.edges.put(edge_id, .{
            .source = edge[0],
            .target = edge[1],
            .weight = 1.0,
        });
        
        // Update adjacency lists
        var out_list = graph.outgoing_edges.get(edge[0]) orelse std.ArrayList(ml.EdgeId).init(allocator);
        try out_list.append(edge_id);
        try graph.outgoing_edges.put(edge[0], out_list);
        
        var in_list = graph.incoming_edges.get(edge[1]) orelse std.ArrayList(ml.EdgeId).init(allocator);
        try in_list.append(edge_id);
        try graph.incoming_edges.put(edge[1], in_list);
        
        edge_id += 1;
    }
    
    // Initialize ML engine
    var ml_engine = ml.MLEngine.init(allocator, &graph);
    defer ml_engine.deinit();
    
    // Generate Node2Vec embeddings
    const params = ml.Node2VecParams{
        .dimensions = 64,
        .walk_length = 10,
        .num_walks = 5,
        .p = 1.0,
        .q = 1.0,
        .window_size = 5,
        .iterations = 3,
    };
    
    const embeddings = try ml_engine.node2vec(params);
    defer {
        var it = embeddings.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        embeddings.deinit();
    }
    
    // Verify embeddings were generated for all nodes
    try testing.expectEqual(@as(u32, 10), embeddings.count());
    
    // Check embedding dimensions
    var emb_it = embeddings.iterator();
    while (emb_it.next()) |entry| {
        try testing.expectEqual(@as(usize, 64), entry.value_ptr.*.len);
        
        // Verify embeddings are not all zeros
        var sum: f32 = 0.0;
        for (entry.value_ptr.*) |val| {
            sum += @abs(val);
        }
        try testing.expect(sum > 0.0);
    }
}

test "PageRank computation" {
    const allocator = testing.allocator;
    
    // Create a simple graph for PageRank
    var graph = ml.GraphData{
        .nodes = std.AutoHashMap(ml.NodeId, void).init(allocator),
        .edges = std.AutoHashMap(ml.EdgeId, ml.GraphData.Edge).init(allocator),
        .outgoing_edges = std.AutoHashMap(ml.NodeId, std.ArrayList(ml.EdgeId)).init(allocator),
        .incoming_edges = std.AutoHashMap(ml.NodeId, std.ArrayList(ml.EdgeId)).init(allocator),
    };
    defer {
        graph.nodes.deinit();
        graph.edges.deinit();
        
        var out_it = graph.outgoing_edges.iterator();
        while (out_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        graph.outgoing_edges.deinit();
        
        var in_it = graph.incoming_edges.iterator();
        while (in_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        graph.incoming_edges.deinit();
    }
    
    // Create a graph with known PageRank structure
    // Node 1 has many incoming links (high PageRank)
    // Node 5 has few incoming links (low PageRank)
    for (1..6) |i| {
        try graph.nodes.put(i, {});
    }
    
    // Add edges: everyone points to node 1
    var edge_id: ml.EdgeId = 1;
    for (2..6) |i| {
        try graph.edges.put(edge_id, .{
            .source = @intCast(i),
            .target = 1,
            .weight = 1.0,
        });
        
        var out_list = graph.outgoing_edges.get(@intCast(i)) orelse std.ArrayList(ml.EdgeId).init(allocator);
        try out_list.append(edge_id);
        try graph.outgoing_edges.put(@intCast(i), out_list);
        
        var in_list = graph.incoming_edges.get(1) orelse std.ArrayList(ml.EdgeId).init(allocator);
        try in_list.append(edge_id);
        try graph.incoming_edges.put(1, in_list);
        
        edge_id += 1;
    }
    
    // Node 1 points to node 2
    try graph.edges.put(edge_id, .{
        .source = 1,
        .target = 2,
        .weight = 1.0,
    });
    
    var out_list = graph.outgoing_edges.get(1) orelse std.ArrayList(ml.EdgeId).init(allocator);
    try out_list.append(edge_id);
    try graph.outgoing_edges.put(1, out_list);
    
    var in_list = graph.incoming_edges.get(2) orelse std.ArrayList(ml.EdgeId).init(allocator);
    try in_list.append(edge_id);
    try graph.incoming_edges.put(2, in_list);
    
    // Initialize ML engine
    var ml_engine = ml.MLEngine.init(allocator, &graph);
    defer ml_engine.deinit();
    
    // Compute PageRank
    const params = ml.PageRankParams{
        .damping_factor = 0.85,
        .max_iterations = 100,
        .tolerance = 1e-6,
    };
    
    const scores = try ml_engine.pagerank(params);
    defer scores.deinit();
    
    // Verify all nodes have scores
    try testing.expectEqual(@as(u32, 5), scores.count());
    
    // Verify scores are positive and sum to approximately 1
    var sum: f32 = 0.0;
    var it = scores.iterator();
    while (it.next()) |entry| {
        try testing.expect(entry.value_ptr.* >= 0.0);
        sum += entry.value_ptr.*;
    }
    
    // Due to damping factor, sum might not be exactly 1
    try testing.expect(@abs(sum - 1.0) < 0.1);
}

test "Link prediction with multiple methods" {
    const allocator = testing.allocator;
    
    // Create a graph for link prediction
    var graph = ml.GraphData{
        .nodes = std.AutoHashMap(ml.NodeId, void).init(allocator),
        .edges = std.AutoHashMap(ml.EdgeId, ml.GraphData.Edge).init(allocator),
        .outgoing_edges = std.AutoHashMap(ml.NodeId, std.ArrayList(ml.EdgeId)).init(allocator),
        .incoming_edges = std.AutoHashMap(ml.NodeId, std.ArrayList(ml.EdgeId)).init(allocator),
    };
    defer {
        graph.nodes.deinit();
        graph.edges.deinit();
        graph.outgoing_edges.deinit();
        graph.incoming_edges.deinit();
    }
    
    // Add nodes
    for (1..7) |i| {
        try graph.nodes.put(i, {});
    }
    
    // Initialize ML engine
    var ml_engine = ml.MLEngine.init(allocator, &graph);
    defer ml_engine.deinit();
    
    // Test different link prediction methods
    const methods = [_]ml.LinkPredictionParams.Method{
        .adamic_adar,
        .jaccard,
        .preferential_attachment,
        .resource_allocation,
    };
    
    for (methods) |method| {
        const params = ml.LinkPredictionParams{
            .method = method,
            .threshold = 0.0, // Get all predictions
            .negative_sampling_ratio = 1.0,
        };
        
        const result = try ml_engine.linkPrediction(params);
        defer allocator.free(result.predictions);
        
        // Should have predictions for non-existing edges
        try testing.expect(result.predictions.len > 0);
        
        // Verify predictions are sorted by score
        for (result.predictions[0..result.predictions.len - 1], result.predictions[1..]) |pred1, pred2| {
            try testing.expect(pred1.score >= pred2.score);
        }
    }
}

test "Community detection with Louvain" {
    const allocator = testing.allocator;
    
    // Create a graph with clear community structure
    var graph = ml.GraphData{
        .nodes = std.AutoHashMap(ml.NodeId, void).init(allocator),
        .edges = std.AutoHashMap(ml.EdgeId, ml.GraphData.Edge).init(allocator),
        .outgoing_edges = std.AutoHashMap(ml.NodeId, std.ArrayList(ml.EdgeId)).init(allocator),
        .incoming_edges = std.AutoHashMap(ml.NodeId, std.ArrayList(ml.EdgeId)).init(allocator),
    };
    defer {
        graph.nodes.deinit();
        graph.edges.deinit();
        graph.outgoing_edges.deinit();
        graph.incoming_edges.deinit();
    }
    
    // Create 3 communities of 5 nodes each
    for (1..16) |i| {
        try graph.nodes.put(i, {});
    }
    
    // Initialize ML engine
    var ml_engine = ml.MLEngine.init(allocator, &graph);
    defer ml_engine.deinit();
    
    // Run Louvain community detection
    const params = ml.LouvainParams{
        .resolution = 1.0,
        .randomize = true,
        .seed = 42,
        .max_iterations = 100,
    };
    
    const result = try ml_engine.louvain(params);
    defer result.communities.deinit();
    
    // Verify all nodes are assigned to communities
    try testing.expectEqual(@as(u32, 15), result.communities.count());
    
    // Verify modularity is in valid range
    try testing.expect(result.modularity >= 0.0);
    try testing.expect(result.modularity <= 1.0);
    
    // Verify number of communities is reasonable
    try testing.expect(result.num_communities > 0);
    try testing.expect(result.num_communities <= 15); // At most one community per node
}

test "GDS procedure registration" {
    const allocator = testing.allocator;
    _ = allocator;
    
    // Verify GDS procedures are registered
    try testing.expect(ml.gds_procedures.len > 0);
    
    // Check specific procedures exist
    var found_node2vec = false;
    var found_pagerank = false;
    var found_louvain = false;
    var found_link_prediction = false;
    
    for (ml.gds_procedures) |proc| {
        if (std.mem.eql(u8, proc.name, "gds.node2vec.stream")) {
            found_node2vec = true;
        } else if (std.mem.eql(u8, proc.name, "gds.pageRank.stream")) {
            found_pagerank = true;
        } else if (std.mem.eql(u8, proc.name, "gds.louvain.stream")) {
            found_louvain = true;
        } else if (std.mem.eql(u8, proc.name, "gds.linkPrediction.mutate")) {
            found_link_prediction = true;
        }
    }
    
    try testing.expect(found_node2vec);
    try testing.expect(found_pagerank);
    try testing.expect(found_louvain);
    try testing.expect(found_link_prediction);
}

test "Embedding similarity computation" {
    const allocator = testing.allocator;
    
    // Create test embeddings
    const emb1 = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const emb2 = [_]f32{ 0.0, 1.0, 0.0, 0.0 };
    const emb3 = [_]f32{ 1.0, 1.0, 0.0, 0.0 }; // Similar to both emb1 and emb2
    const emb4 = [_]f32{ 1.0, 0.0, 0.0, 0.0 }; // Identical to emb1
    
    // Test cosine similarity
    const sim1_2 = ml.cosineSimilarity(&emb1, &emb2);
    const sim1_3 = ml.cosineSimilarity(&emb1, &emb3);
    const sim1_4 = ml.cosineSimilarity(&emb1, &emb4);
    
    // Orthogonal vectors should have similarity 0
    try testing.expect(@abs(sim1_2) < 0.001);
    
    // Identical vectors should have similarity 1
    try testing.expect(@abs(sim1_4 - 1.0) < 0.001);
    
    // Partially similar vectors should have intermediate similarity
    try testing.expect(sim1_3 > 0.0 and sim1_3 < 1.0);
}

test "ML engine memory management" {
    const allocator = testing.allocator;
    
    // Create a graph
    var graph = ml.GraphData{
        .nodes = std.AutoHashMap(ml.NodeId, void).init(allocator),
        .edges = std.AutoHashMap(ml.EdgeId, ml.GraphData.Edge).init(allocator),
        .outgoing_edges = std.AutoHashMap(ml.NodeId, std.ArrayList(ml.EdgeId)).init(allocator),
        .incoming_edges = std.AutoHashMap(ml.NodeId, std.ArrayList(ml.EdgeId)).init(allocator),
    };
    defer {
        graph.nodes.deinit();
        graph.edges.deinit();
        graph.outgoing_edges.deinit();
        graph.incoming_edges.deinit();
    }
    
    // Add many nodes to test memory handling
    for (1..101) |i| {
        try graph.nodes.put(i, {});
    }
    
    // Create and destroy ML engine multiple times
    for (0..10) |_| {
        var ml_engine = ml.MLEngine.init(allocator, &graph);
        
        // Generate embeddings
        const params = ml.Node2VecParams{
            .dimensions = 32,
            .walk_length = 5,
            .num_walks = 2,
        };
        
        const embeddings = try ml_engine.node2vec(params);
        
        // Clean up embeddings
        var it = embeddings.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        embeddings.deinit();
        
        ml_engine.deinit();
    }
    
    // If we get here without memory errors, the test passes
    try testing.expect(true);
}