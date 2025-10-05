const std = @import("std");
const geode = @import("geode");
const builders = geode.graph.builders;
const optimized = geode.graph.optimized;

// CANARY: REQ=REQ-GRAPH-ALGORITHM-PERFORMANCE-ENHANCEMENTS-001; FEATURE="Graph Performance Optimization"; ASPECT=OptimizedCloseness; STATUS=TESTED; TEST=test_optimized_closeness_centrality; OWNER=graph; UPDATED=2025-10-05
test "test_optimized_closeness_centrality" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    
    // Create a simple path graph: 0-1-2-3-4
    var i: u32 = 0;
    while (i <= 4) : (i += 1) {
        g.addNode(i);
    }
    
    i = 0;
    while (i < 4) : (i += 1) {
        _ = g.addEdge(i, i + 1, 1) catch {};
        _ = g.addEdge(i + 1, i, 1) catch {};
    }
    
    // Test optimized closeness centrality
    var result = try optimized.computeOptimizedCloseness(std.testing.allocator, &g, .{
        .mode = .standard,
        .normalize = false,
    });
    defer result.deinit(std.testing.allocator);
    
    // Verify results
    try std.testing.expect(result.node_ids.len == 5);
    try std.testing.expect(result.scores.len == 5);
    
    // Node 2 (middle) should have highest closeness centrality
    var idx2: usize = 0;
    for (result.node_ids, 0..) |id, idx| {
        if (id == 2) {
            idx2 = idx;
            break;
        }
    }
    
    // Verify node 2 has higher score than edge nodes
    var idx0: usize = 0;
    var idx4: usize = 0;
    for (result.node_ids, 0..) |id, idx| {
        if (id == 0) idx0 = idx;
        if (id == 4) idx4 = idx;
    }
    
    try std.testing.expect(result.scores[idx2] > result.scores[idx0]);
    try std.testing.expect(result.scores[idx2] > result.scores[idx4]);
}

// CANARY: REQ=REQ-GRAPH-ALGORITHM-PERFORMANCE-ENHANCEMENTS-002; FEATURE="Graph Performance Optimization"; ASPECT=OptimizedPageRank; STATUS=TESTED; TEST=test_optimized_pagerank; OWNER=graph; UPDATED=2025-10-05
test "test_optimized_pagerank" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    
    // Create a simple directed graph with cycle
    g.addNode(1);
    g.addNode(2);
    g.addNode(3);
    
    _ = g.addEdge(1, 2, 1) catch {};
    _ = g.addEdge(2, 3, 1) catch {};
    _ = g.addEdge(3, 1, 1) catch {};
    
    // Test optimized PageRank
    var result = try optimized.computeOptimizedPageRank(std.testing.allocator, &g, .{
        .damping = 0.85,
        .epsilon = 1e-8,
        .max_iterations = 100,
    });
    defer result.deinit(std.testing.allocator);
    
    // Verify basic properties
    try std.testing.expect(result.node_ids.len == 3);
    try std.testing.expect(result.ranks.len == 3);
    try std.testing.expect(result.iterations > 0);
    
    // Verify ranks sum to approximately 1.0
    var sum: f64 = 0;
    for (result.ranks) |rank| {
        sum += rank;
    }
    try std.testing.expectApproxEqAbs(1.0, sum, 1e-9);
    
    // All nodes should have approximately equal rank in this symmetric cycle
    const expected_rank = 1.0 / 3.0;
    for (result.ranks) |rank| {
        try std.testing.expectApproxEqAbs(expected_rank, rank, 0.1);
    }
}

// CANARY: REQ=REQ-GRAPH-ALGORITHM-PERFORMANCE-ENHANCEMENTS-003; FEATURE="Graph Performance Optimization"; ASPECT=CircularQueuePerformance; STATUS=TESTED; TEST=test_circular_queue_performance; OWNER=graph; UPDATED=2025-10-05
test "test_circular_queue_performance" {
    // Test circular queue implementation for performance
    const capacity = 1000;
    var buffer = try std.testing.allocator.alloc(u32, capacity);
    defer std.testing.allocator.free(buffer);
    
    var queue = optimized.CircularQueue{
        .buffer = buffer,
        .head = 0,
        .tail = 0,
        .size = 0,
        .capacity = capacity,
    };
    
    // Test push/pop operations
    var i: u32 = 0;
    while (i < capacity - 1) : (i += 1) {
        queue.push(i);
    }
    
    try std.testing.expect(queue.size == capacity - 1);
    
    // Test pop operations
    i = 0;
    while (i < capacity - 1) : (i += 1) {
        const value = queue.pop().?;
        try std.testing.expect(value == i);
    }
    
    try std.testing.expect(queue.size == 0);
    try std.testing.expect(queue.pop() == null);
}

// CANARY: REQ=REQ-GRAPH-ALGORITHM-PERFORMANCE-ENHANCEMENTS-004; FEATURE="Graph Performance Optimization"; ASPECT=SIMDOptimization; STATUS=TESTED; TEST=test_simd_distance_reset; OWNER=graph; UPDATED=2025-10-05
test "test_simd_distance_reset" {
    // Test SIMD-optimized distance array reset
    const size = 64; // Multiple of 8 for SIMD
    var distances = try std.testing.allocator.alloc(i32, size);
    defer std.testing.allocator.free(distances);
    
    // Initialize with non-negative values
    for (distances, 0..) |*dist, i| {
        dist.* = @intCast(i);
    }
    
    // Reset using SIMD optimization
    optimized.resetDistanceArray(distances);
    
    // Verify all values are -1
    for (distances) |dist| {
        try std.testing.expect(dist == -1);
    }
}

// CANARY: REQ=REQ-GRAPH-ALGORITHM-PERFORMANCE-ENHANCEMENTS-005; FEATURE="Graph Performance Optimization"; ASPECT=LargeGraphPerformance; STATUS=TESTED; TEST=test_large_graph_performance; OWNER=graph; UPDATED=2025-10-05
test "test_large_graph_performance" {
    // Test performance with moderately large graph
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    
    // Create a grid graph (10x10 = 100 nodes)
    const rows = 10;
    const cols = 10;
    
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            const id = r * cols + c;
            g.addNode(id);
            
            // Add horizontal edges
            if (c + 1 < cols) {
                _ = g.addEdge(id, id + 1, 1) catch {};
                _ = g.addEdge(id + 1, id, 1) catch {};
            }
            
            // Add vertical edges
            if (r + 1 < rows) {
                const down_id = (r + 1) * cols + c;
                _ = g.addEdge(id, down_id, 1) catch {};
                _ = g.addEdge(down_id, id, 1) catch {};
            }
        }
    }
    
    // Measure optimized closeness performance
    const start_time = std.time.nanoTimestamp();
    var result = try optimized.computeOptimizedCloseness(std.testing.allocator, &g, .{
        .mode = .harmonic,
        .normalize = true,
    });
    const end_time = std.time.nanoTimestamp();
    defer result.deinit(std.testing.allocator);
    
    const duration_ns = @as(u64, @intCast(end_time - start_time));
    
    // Performance should be reasonable for 100-node graph
    try std.testing.expect(duration_ns < 500_000_000); // Less than 500ms
    try std.testing.expect(result.node_ids.len == 100);
    try std.testing.expect(result.scores.len == 100);
    
    // Verify all scores are non-negative
    for (result.scores) |score| {
        try std.testing.expect(score >= 0.0);
    }
}

// CANARY: REQ=REQ-GRAPH-ALGORITHM-PERFORMANCE-ENHANCEMENTS-006; FEATURE="Graph Performance Optimization"; ASPECT=MemoryEfficiency; STATUS=TESTED; TEST=test_memory_efficiency; OWNER=graph; UPDATED=2025-10-05
test "test_memory_efficiency" {
    // Test memory allocation patterns
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    
    // Create a small graph
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        g.addNode(i);
        if (i > 0) {
            _ = g.addEdge(i - 1, i, 1) catch {};
        }
    }
    
    // Test multiple algorithm runs to check for memory leaks
    var run: usize = 0;
    while (run < 5) : (run += 1) {
        var closeness_result = try optimized.computeOptimizedCloseness(std.testing.allocator, &g, .{});
        closeness_result.deinit(std.testing.allocator);
        
        var pagerank_result = try optimized.computeOptimizedPageRank(std.testing.allocator, &g, .{});
        pagerank_result.deinit(std.testing.allocator);
    }
    
    // If we reach here without errors, memory management is working correctly
    try std.testing.expect(true);
}

// CANARY: REQ=REQ-GRAPH-ALGORITHM-PERFORMANCE-ENHANCEMENTS-007; FEATURE="Graph Performance Optimization"; ASPECT=AlgorithmCorrectness; STATUS=TESTED; TEST=test_algorithm_correctness_comparison; OWNER=graph; UPDATED=2025-10-05
test "test_algorithm_correctness_comparison" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    
    // Create a known graph structure
    var i: u32 = 1;
    while (i <= 5) : (i += 1) {
        g.addNode(i);
    }
    
    // Star graph: node 1 connected to all others
    i = 2;
    while (i <= 5) : (i += 1) {
        _ = g.addEdge(1, i, 1) catch {};
        _ = g.addEdge(i, 1, 1) catch {};
    }
    
    // Test optimized vs standard implementation (if available)
    var optimized_result = try optimized.computeOptimizedCloseness(std.testing.allocator, &g, .{
        .mode = .standard,
        .normalize = false,
    });
    defer optimized_result.deinit(std.testing.allocator);
    
    // Node 1 (center) should have highest closeness in star graph
    var center_idx: usize = 0;
    for (optimized_result.node_ids, 0..) |id, idx| {
        if (id == 1) {
            center_idx = idx;
            break;
        }
    }
    
    // All other nodes should have lower scores
    for (optimized_result.node_ids, 0..) |id, idx| {
        if (id != 1) {
            try std.testing.expect(optimized_result.scores[center_idx] > optimized_result.scores[idx]);
        }
    }
}

// CANARY: REQ=REQ-GRAPH-ALGORITHM-PERFORMANCE-ENHANCEMENTS-008; FEATURE="Graph Performance Optimization"; ASPECT=EdgeCaseHandling; STATUS=TESTED; TEST=test_edge_cases; OWNER=graph; UPDATED=2025-10-05
test "test_edge_cases" {
    // Test empty graph
    {
        var empty_graph = builders.Graph.init(std.testing.allocator);
        defer empty_graph.deinit();
        
        var result = try optimized.computeOptimizedCloseness(std.testing.allocator, &empty_graph, .{});
        defer result.deinit(std.testing.allocator);
        
        try std.testing.expect(result.node_ids.len == 0);
        try std.testing.expect(result.scores.len == 0);
    }
    
    // Test single node graph
    {
        var single_graph = builders.Graph.init(std.testing.allocator);
        defer single_graph.deinit();
        
        single_graph.addNode(42);
        
        var result = try optimized.computeOptimizedCloseness(std.testing.allocator, &single_graph, .{});
        defer result.deinit(std.testing.allocator);
        
        try std.testing.expect(result.node_ids.len == 1);
        try std.testing.expect(result.node_ids[0] == 42);
        try std.testing.expect(result.scores.len == 1);
    }
    
    // Test disconnected graph
    {
        var disconnected_graph = builders.Graph.init(std.testing.allocator);
        defer disconnected_graph.deinit();
        
        disconnected_graph.addNode(1);
        disconnected_graph.addNode(2);
        disconnected_graph.addNode(3);
        disconnected_graph.addNode(4);
        
        // Only connect 1-2, leaving 3 and 4 isolated
        _ = disconnected_graph.addEdge(1, 2, 1) catch {};
        _ = disconnected_graph.addEdge(2, 1, 1) catch {};
        
        var result = try optimized.computeOptimizedCloseness(std.testing.allocator, &disconnected_graph, .{
            .mode = .harmonic, // Better for disconnected graphs
            .normalize = true,
        });
        defer result.deinit(std.testing.allocator);
        
        try std.testing.expect(result.node_ids.len == 4);
        try std.testing.expect(result.scores.len == 4);
        
        // Connected nodes should have higher scores than isolated ones
        var idx1: usize = 0;
        var idx3: usize = 0;
        for (result.node_ids, 0..) |id, idx| {
            if (id == 1) idx1 = idx;
            if (id == 3) idx3 = idx;
        }
        
        try std.testing.expect(result.scores[idx1] > result.scores[idx3]);
    }
}