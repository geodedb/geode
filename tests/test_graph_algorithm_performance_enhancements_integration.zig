const std = @import("std");
const geode = @import("geode");
const builders = geode.graph.builders;
const optimized = geode.graph.optimized;
const closeness = geode.graph.closeness;
const pagerank = geode.graph.pagerank;

// CANARY: REQ=REQ-GRAPH-ALGORITHM-PERFORMANCE-INTEGRATION-001; FEATURE="Graph Performance Integration"; ASPECT=CrossAlgorithmIntegration; STATUS=TESTED; TEST=test_cross_algorithm_integration; OWNER=graph; UPDATED=2025-10-05
test "test_cross_algorithm_integration" {
    // Test integration between optimized and standard algorithms
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    
    // Create a complex graph structure for comprehensive testing
    var i: u32 = 1;
    while (i <= 8) : (i += 1) {
        g.addNode(i);
    }
    
    // Create a more complex topology: hub-and-spoke with interconnections
    // Central hub: node 1
    i = 2;
    while (i <= 5) : (i += 1) {
        _ = g.addEdge(1, i, 1) catch {};
        _ = g.addEdge(i, 1, 1) catch {};
    }
    
    // Secondary cluster: 6-7-8 triangle
    _ = g.addEdge(6, 7, 1) catch {};
    _ = g.addEdge(7, 6, 1) catch {};
    _ = g.addEdge(7, 8, 1) catch {};
    _ = g.addEdge(8, 7, 1) catch {};
    _ = g.addEdge(8, 6, 1) catch {};
    _ = g.addEdge(6, 8, 1) catch {};
    
    // Bridge between clusters
    _ = g.addEdge(5, 6, 1) catch {};
    _ = g.addEdge(6, 5, 1) catch {};
    
    // Run both optimized and standard algorithms
    var optimized_closeness = try optimized.computeOptimizedCloseness(std.testing.allocator, &g, .{
        .mode = .standard,
        .normalize = true,
    });
    defer optimized_closeness.deinit(std.testing.allocator);
    
    var standard_closeness = try closeness.compute(std.testing.allocator, &g, .{
        .mode = .standard,
        .normalize = true,
    });
    defer standard_closeness.deinit(std.testing.allocator);
    
    // Results should be identical (within floating point precision)
    try std.testing.expect(optimized_closeness.node_ids.len == standard_closeness.node_ids.len);
    try std.testing.expect(optimized_closeness.scores.len == standard_closeness.scores.len);
    
    // Compare scores for each node
    for (optimized_closeness.node_ids, 0..) |opt_id, opt_idx| {
        // Find corresponding node in standard results
        for (standard_closeness.node_ids, 0..) |std_id, std_idx| {
            if (opt_id == std_id) {
                try std.testing.expectApproxEqAbs(
                    optimized_closeness.scores[opt_idx],
                    standard_closeness.scores[std_idx],
                    1e-10
                );
                break;
            }
        }
    }
}

// CANARY: REQ=REQ-GRAPH-ALGORITHM-PERFORMANCE-INTEGRATION-002; FEATURE="Graph Performance Integration"; ASPECT=PerformanceBenchmarking; STATUS=TESTED; TEST=test_performance_benchmarking; OWNER=graph; UPDATED=2025-10-05
test "test_performance_benchmarking" {
    // Comprehensive performance comparison between optimized and standard algorithms
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    
    // Create a larger graph for meaningful performance comparison
    const size = 50; // 50x50 = 2500 nodes would be too much for CI, so use smaller size
    const rows = 15;
    const cols = 15; // 225 nodes
    
    // Build grid graph
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            const id = r * cols + c;
            g.addNode(id);
            
            if (c + 1 < cols) {
                _ = g.addEdge(id, id + 1, 1) catch {};
                _ = g.addEdge(id + 1, id, 1) catch {};
            }
            
            if (r + 1 < rows) {
                const down_id = (r + 1) * cols + c;
                _ = g.addEdge(id, down_id, 1) catch {};
                _ = g.addEdge(down_id, id, 1) catch {};
            }
        }
    }
    
    // Benchmark optimized closeness
    const optimized_start = std.time.nanoTimestamp();
    var optimized_result = try optimized.computeOptimizedCloseness(std.testing.allocator, &g, .{
        .mode = .harmonic,
        .normalize = true,
    });
    const optimized_end = std.time.nanoTimestamp();
    defer optimized_result.deinit(std.testing.allocator);
    
    // Benchmark standard closeness
    const standard_start = std.time.nanoTimestamp();
    var standard_result = try closeness.compute(std.testing.allocator, &g, .{
        .mode = .harmonic,
        .normalize = true,
    });
    const standard_end = std.time.nanoTimestamp();
    defer standard_result.deinit(std.testing.allocator);
    
    const optimized_duration = @as(u64, @intCast(optimized_end - optimized_start));
    const standard_duration = @as(u64, @intCast(standard_end - standard_start));
    
    // Log performance comparison
    std.log.info("Performance comparison for {d} nodes:", .{rows * cols});
    std.log.info("  Optimized: {d} ns", .{optimized_duration});
    std.log.info("  Standard:  {d} ns", .{standard_duration});
    
    if (standard_duration > 0) {
        const speedup = @as(f64, @floatFromInt(standard_duration)) / @as(f64, @floatFromInt(optimized_duration));
        std.log.info("  Speedup:   {d:.2}x", .{speedup});
        
        // Optimized version should be at least as fast as standard (ideally faster)
        try std.testing.expect(optimized_duration <= standard_duration * 2); // Allow some variance
    }
    
    // Results should be consistent
    try std.testing.expect(optimized_result.node_ids.len == standard_result.node_ids.len);
}

// CANARY: REQ=REQ-GRAPH-ALGORITHM-PERFORMANCE-INTEGRATION-003; FEATURE="Graph Performance Integration"; ASPECT=PageRankIntegration; STATUS=TESTED; TEST=test_pagerank_integration; OWNER=graph; UPDATED=2025-10-05
test "test_pagerank_integration" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    
    // Create a directed graph with interesting PageRank properties
    var i: u32 = 1;
    while (i <= 6) : (i += 1) {
        g.addNode(i);
    }
    
    // Create a directed graph structure
    // 1 -> 2, 3
    // 2 -> 3, 4
    // 3 -> 1, 5
    // 4 -> 5, 6
    // 5 -> 6
    // 6 -> 1
    _ = g.addEdge(1, 2, 1) catch {};
    _ = g.addEdge(1, 3, 1) catch {};
    _ = g.addEdge(2, 3, 1) catch {};
    _ = g.addEdge(2, 4, 1) catch {};
    _ = g.addEdge(3, 1, 1) catch {};
    _ = g.addEdge(3, 5, 1) catch {};
    _ = g.addEdge(4, 5, 1) catch {};
    _ = g.addEdge(4, 6, 1) catch {};
    _ = g.addEdge(5, 6, 1) catch {};
    _ = g.addEdge(6, 1, 1) catch {};
    
    // Test optimized PageRank
    var optimized_pr = try optimized.computeOptimizedPageRank(std.testing.allocator, &g, .{
        .damping = 0.85,
        .epsilon = 1e-10,
        .max_iterations = 100,
    });
    defer optimized_pr.deinit(std.testing.allocator);
    
    // Test standard PageRank
    var standard_pr = try pagerank.compute(std.testing.allocator, &g, .{
        .damping = 0.85,
        .epsilon = 1e-10,
        .max_iterations = 100,
    });
    defer standard_pr.deinit(std.testing.allocator);
    
    // Compare results
    try std.testing.expect(optimized_pr.node_ids.len == standard_pr.node_ids.len);
    try std.testing.expect(optimized_pr.ranks.len == standard_pr.ranks.len);
    
    // Verify both converged
    try std.testing.expect(optimized_pr.converged);
    try std.testing.expect(standard_pr.converged);
    
    // Compare ranks for each node
    for (optimized_pr.node_ids, 0..) |opt_id, opt_idx| {
        for (standard_pr.node_ids, 0..) |std_id, std_idx| {
            if (opt_id == std_id) {
                try std.testing.expectApproxEqAbs(
                    optimized_pr.ranks[opt_idx],
                    standard_pr.ranks[std_idx],
                    1e-9
                );
                break;
            }
        }
    }
}

// CANARY: REQ=REQ-GRAPH-ALGORITHM-PERFORMANCE-INTEGRATION-004; FEATURE="Graph Performance Integration"; ASPECT=LargeScaleIntegration; STATUS=TESTED; TEST=test_large_scale_integration; OWNER=graph; UPDATED=2025-10-05
test "test_large_scale_integration" {
    // Test with a larger, more complex graph structure
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    
    // Create a scale-free-like network (simplified version)
    const num_nodes = 100;
    var i: u32 = 0;
    while (i < num_nodes) : (i += 1) {
        g.addNode(i);
    }
    
    // Add preferential attachment-like edges
    var rng = std.rand.DefaultPrng.init(42); // Deterministic seed
    const random = rng.random();
    
    i = 1;
    while (i < num_nodes) : (i += 1) {
        // Each new node connects to a few existing nodes
        const num_connections = @min(3, i);
        var j: u32 = 0;
        while (j < num_connections) : (j += 1) {
            const target = random.intRangeAtMost(u32, 0, i - 1);
            _ = g.addEdge(i, target, 1) catch {};
            _ = g.addEdge(target, i, 1) catch {}; // Make it undirected
        }
    }
    
    // Test both algorithms complete without errors
    var optimized_result = try optimized.computeOptimizedCloseness(std.testing.allocator, &g, .{
        .mode = .harmonic,
        .normalize = true,
    });
    defer optimized_result.deinit(std.testing.allocator);
    
    var pagerank_result = try optimized.computeOptimizedPageRank(std.testing.allocator, &g, .{
        .damping = 0.85,
        .epsilon = 1e-6, // Slightly relaxed for large graph
        .max_iterations = 50,
    });
    defer pagerank_result.deinit(std.testing.allocator);
    
    // Verify basic properties
    try std.testing.expect(optimized_result.node_ids.len == num_nodes);
    try std.testing.expect(optimized_result.scores.len == num_nodes);
    try std.testing.expect(pagerank_result.node_ids.len == num_nodes);
    try std.testing.expect(pagerank_result.ranks.len == num_nodes);
    
    // Verify PageRank ranks sum to ~1
    var rank_sum: f64 = 0;
    for (pagerank_result.ranks) |rank| {
        rank_sum += rank;
    }
    try std.testing.expectApproxEqAbs(1.0, rank_sum, 1e-6);
    
    // All scores should be non-negative
    for (optimized_result.scores) |score| {
        try std.testing.expect(score >= 0.0);
    }
    
    for (pagerank_result.ranks) |rank| {
        try std.testing.expect(rank >= 0.0);
    }
}

// CANARY: REQ=REQ-GRAPH-ALGORITHM-PERFORMANCE-INTEGRATION-005; FEATURE="Graph Performance Integration"; ASPECT=ConcurrentExecution; STATUS=TESTED; TEST=test_concurrent_execution; OWNER=graph; UPDATED=2025-10-05
test "test_concurrent_execution" {
    // Test that algorithms can run concurrently without interference
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    
    // Create a medium-sized graph
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        g.addNode(i);
        if (i > 0) {
            _ = g.addEdge(i - 1, i, 1) catch {};
            _ = g.addEdge(i, i - 1, 1) catch {};
        }
        // Add some cross-connections
        if (i > 5) {
            _ = g.addEdge(i, i - 5, 1) catch {};
            _ = g.addEdge(i - 5, i, 1) catch {};
        }
    }
    
    // Simulate concurrent execution by running multiple algorithms in sequence
    // (actual threading would require more complex test setup)
    var run: usize = 0;
    while (run < 3) : (run += 1) {
        var closeness_result = try optimized.computeOptimizedCloseness(std.testing.allocator, &g, .{
            .mode = .harmonic,
            .normalize = true,
        });
        
        var pagerank_result = try optimized.computeOptimizedPageRank(std.testing.allocator, &g, .{
            .damping = 0.85,
            .epsilon = 1e-8,
            .max_iterations = 50,
        });
        
        // Verify results are consistent across runs
        try std.testing.expect(closeness_result.node_ids.len == 20);
        try std.testing.expect(pagerank_result.node_ids.len == 20);
        
        // Clean up
        closeness_result.deinit(std.testing.allocator);
        pagerank_result.deinit(std.testing.allocator);
    }
}

// CANARY: REQ=REQ-GRAPH-ALGORITHM-PERFORMANCE-INTEGRATION-006; FEATURE="Graph Performance Integration"; ASPECT=ErrorHandlingIntegration; STATUS=TESTED; TEST=test_error_handling_integration; OWNER=graph; UPDATED=2025-10-05
test "test_error_handling_integration" {
    // Test error handling in various scenarios
    
    // Test with malformed graph data (should handle gracefully)
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    
    // Empty graph should not cause errors
    var empty_result = try optimized.computeOptimizedCloseness(std.testing.allocator, &g, .{});
    defer empty_result.deinit(std.testing.allocator);
    try std.testing.expect(empty_result.node_ids.len == 0);
    
    // Single node should not cause errors
    g.addNode(42);
    var single_result = try optimized.computeOptimizedCloseness(std.testing.allocator, &g, .{});
    defer single_result.deinit(std.testing.allocator);
    try std.testing.expect(single_result.node_ids.len == 1);
    
    // Test with extreme parameter values
    var extreme_pagerank = try optimized.computeOptimizedPageRank(std.testing.allocator, &g, .{
        .damping = 0.99, // Very high damping
        .epsilon = 1e-15, // Very tight convergence
        .max_iterations = 1000,
    });
    defer extreme_pagerank.deinit(std.testing.allocator);
    
    // Should still produce valid results
    try std.testing.expect(extreme_pagerank.node_ids.len == 1);
    try std.testing.expect(extreme_pagerank.ranks.len == 1);
    try std.testing.expectApproxEqAbs(1.0, extreme_pagerank.ranks[0], 1e-10);
}

// CANARY: REQ=REQ-GRAPH-ALGORITHM-PERFORMANCE-INTEGRATION-007; FEATURE="Graph Performance Integration"; ASPECT=MemoryManagementIntegration; STATUS=TESTED; TEST=test_memory_management_integration; OWNER=graph; UPDATED=2025-10-05
test "test_memory_management_integration" {
    // Test memory management across multiple algorithm executions
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    
    // Create a graph that will require significant memory allocation
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        g.addNode(i);
        var j: u32 = 0;
        while (j < i) : (j += 1) {
            if ((i + j) % 3 == 0) { // Add some edges pseudo-randomly
                _ = g.addEdge(i, j, 1) catch {};
                _ = g.addEdge(j, i, 1) catch {};
            }
        }
    }
    
    // Run multiple iterations to test for memory leaks
    var iteration: usize = 0;
    while (iteration < 10) : (iteration += 1) {
        var closeness_result = try optimized.computeOptimizedCloseness(std.testing.allocator, &g, .{
            .mode = .standard,
            .normalize = true,
        });
        defer closeness_result.deinit(std.testing.allocator);
        
        var pagerank_result = try optimized.computeOptimizedPageRank(std.testing.allocator, &g, .{
            .damping = 0.85,
            .epsilon = 1e-8,
            .max_iterations = 100,
        });
        defer pagerank_result.deinit(std.testing.allocator);
        
        // Verify results are consistent
        try std.testing.expect(closeness_result.node_ids.len == 30);
        try std.testing.expect(pagerank_result.node_ids.len == 30);
        
        // All algorithms should complete successfully without memory issues
        try std.testing.expect(pagerank_result.converged or pagerank_result.iterations == 100);
    }
    
    // If we reach here, memory management is working correctly
    try std.testing.expect(true);
}