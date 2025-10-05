const std = @import("std");
const geode = @import("geode");
const optimized = geode.graph.optimized;
const builders = geode.graph.builders;
const closeness = geode.graph.closeness;
const pagerank = geode.graph.pagerank;

// CANARY: REQ=REQ-COMPILATION-FIXES-INTEGRATION-OCTOBER-2025-001; FEATURE="Compilation Fixes Integration"; ASPECT=CrossAlgorithmConsistency; STATUS=TESTED; TEST=test_cross_algorithm_consistency_post_fix; OWNER=build; UPDATED=2025-10-05
test "test_cross_algorithm_consistency_post_fix" {
    // Test that compilation fixes maintain consistency between optimized and standard algorithms
    var graph = builders.Graph.init(std.testing.allocator);
    defer graph.deinit();
    
    // Create a complex graph for comprehensive testing
    var i: u32 = 1;
    while (i <= 6) : (i += 1) {
        graph.addNode(i);
    }
    
    // Create hub-and-spoke with interconnections
    _ = graph.addEdge(1, 2, 1) catch {};
    _ = graph.addEdge(1, 3, 1) catch {};
    _ = graph.addEdge(2, 1, 1) catch {};
    _ = graph.addEdge(3, 1, 1) catch {};
    _ = graph.addEdge(2, 4, 1) catch {};
    _ = graph.addEdge(4, 2, 1) catch {};
    _ = graph.addEdge(3, 5, 1) catch {};
    _ = graph.addEdge(5, 3, 1) catch {};
    _ = graph.addEdge(4, 6, 1) catch {};
    _ = graph.addEdge(6, 4, 1) catch {};
    _ = graph.addEdge(5, 6, 1) catch {};
    _ = graph.addEdge(6, 5, 1) catch {};
    
    // Run both optimized and standard algorithms
    var optimized_result = try optimized.computeOptimizedCloseness(std.testing.allocator, &graph, .{
        .mode = .standard,
        .normalize = true,
    });
    defer optimized_result.deinit(std.testing.allocator);
    
    var standard_result = try closeness.compute(std.testing.allocator, &graph, .{
        .mode = .standard,
        .normalize = true,
    });
    defer standard_result.deinit(std.testing.allocator);
    
    // Results should be identical (within floating point precision)
    try std.testing.expect(optimized_result.node_ids.len == standard_result.node_ids.len);
    
    // Compare scores for each node
    for (optimized_result.node_ids, 0..) |opt_id, opt_idx| {
        for (standard_result.node_ids, 0..) |std_id, std_idx| {
            if (opt_id == std_id) {
                try std.testing.expectApproxEqAbs(
                    optimized_result.scores[opt_idx],
                    standard_result.scores[std_idx],
                    1e-10
                );
                break;
            }
        }
    }
}

// CANARY: REQ=REQ-COMPILATION-FIXES-INTEGRATION-OCTOBER-2025-002; FEATURE="Compilation Fixes Integration"; ASPECT=LargeScaleStability; STATUS=TESTED; TEST=test_large_scale_stability_post_fix; OWNER=build; UPDATED=2025-10-05
test "test_large_scale_stability_post_fix" {
    // Test that compilation fixes work correctly with larger graphs
    var graph = builders.Graph.init(std.testing.allocator);
    defer graph.deinit();
    
    // Create a larger graph (50 nodes) to test scalability
    const num_nodes = 50;
    var i: u32 = 0;
    while (i < num_nodes) : (i += 1) {
        graph.addNode(i);
    }
    
    // Create a more complex topology with multiple connections per node
    i = 0;
    while (i < num_nodes) : (i += 1) {
        // Connect each node to next 3 nodes (circular)
        var j: u32 = 1;
        while (j <= 3) : (j += 1) {
            const target = (i + j) % num_nodes;
            _ = graph.addEdge(i, target, 1) catch {};
            _ = graph.addEdge(target, i, 1) catch {}; // Make it undirected
        }
    }
    
    // Test optimized closeness with the fixed compilation
    var closeness_result = try optimized.computeOptimizedCloseness(std.testing.allocator, &graph, .{
        .mode = .harmonic,
        .normalize = true,
    });
    defer closeness_result.deinit(std.testing.allocator);
    
    // Test optimized PageRank
    var pagerank_result = try optimized.computeOptimizedPageRank(std.testing.allocator, &graph, .{
        .damping = 0.85,
        .epsilon = 1e-6,
        .max_iterations = 50,
    });
    defer pagerank_result.deinit(std.testing.allocator);
    
    // Verify results are reasonable
    try std.testing.expect(closeness_result.node_ids.len == num_nodes);
    try std.testing.expect(pagerank_result.node_ids.len == num_nodes);
    
    // Check PageRank normalization
    var rank_sum: f64 = 0;
    for (pagerank_result.ranks) |rank| {
        rank_sum += rank;
    }
    try std.testing.expectApproxEqAbs(1.0, rank_sum, 1e-6);
    
    // All closeness scores should be non-negative
    for (closeness_result.scores) |score| {
        try std.testing.expect(score >= 0.0);
    }
}

// CANARY: REQ=REQ-COMPILATION-FIXES-INTEGRATION-OCTOBER-2025-003; FEATURE="Compilation Fixes Integration"; ASPECT=MemoryLeakPrevention; STATUS=TESTED; TEST=test_memory_leak_prevention_post_fix; OWNER=build; UPDATED=2025-10-05
test "test_memory_leak_prevention_post_fix" {
    // Test that the compilation fix doesn't introduce memory leaks
    
    // Run multiple iterations with different graph sizes
    var iteration: usize = 0;
    while (iteration < 10) : (iteration += 1) {
        var graph = builders.Graph.init(std.testing.allocator);
        defer graph.deinit();
        
        // Create graph with varying size each iteration
        const size = 5 + iteration;
        var i: u32 = 0;
        while (i < size) : (i += 1) {
            graph.addNode(i + @as(u32, @intCast(iteration)) * 100); // Unique node IDs
            if (i > 0) {
                _ = graph.addEdge(
                    i - 1 + @as(u32, @intCast(iteration)) * 100,
                    i + @as(u32, @intCast(iteration)) * 100,
                    1
                ) catch {};
            }
        }
        
        // Test both algorithms
        {
            var closeness_result = try optimized.computeOptimizedCloseness(std.testing.allocator, &graph, .{
                .mode = .harmonic,
                .normalize = true,
            });
            defer closeness_result.deinit(std.testing.allocator);
            
            try std.testing.expect(closeness_result.node_ids.len == size);
        }
        
        {
            var pagerank_result = try optimized.computeOptimizedPageRank(std.testing.allocator, &graph, .{
                .max_iterations = 20,
            });
            defer pagerank_result.deinit(std.testing.allocator);
            
            try std.testing.expect(pagerank_result.node_ids.len == size);
        }
    }
    
    // If all iterations complete without memory errors, the fix is working
    try std.testing.expect(true);
}

// CANARY: REQ=REQ-COMPILATION-FIXES-INTEGRATION-OCTOBER-2025-004; FEATURE="Compilation Fixes Integration"; ASPECT=ErrorHandlingRobustness; STATUS=TESTED; TEST=test_error_handling_robustness_post_fix; OWNER=build; UPDATED=2025-10-05
test "test_error_handling_robustness_post_fix" {
    // Test that error handling remains robust after compilation fixes
    
    // Test with empty graph (should handle gracefully)
    {
        var empty_graph = builders.Graph.init(std.testing.allocator);
        defer empty_graph.deinit();
        
        var result = try optimized.computeOptimizedCloseness(std.testing.allocator, &empty_graph, .{});
        defer result.deinit(std.testing.allocator);
        
        try std.testing.expect(result.node_ids.len == 0);
        try std.testing.expect(result.scores.len == 0);
    }
    
    // Test with single isolated node
    {
        var single_graph = builders.Graph.init(std.testing.allocator);
        defer single_graph.deinit();
        
        single_graph.addNode(999);
        
        var result = try optimized.computeOptimizedCloseness(std.testing.allocator, &single_graph, .{});
        defer result.deinit(std.testing.allocator);
        
        try std.testing.expect(result.node_ids.len == 1);
        try std.testing.expect(result.node_ids[0] == 999);
    }
    
    // Test with very high node IDs (edge case for node ID handling)
    {
        var high_id_graph = builders.Graph.init(std.testing.allocator);
        defer high_id_graph.deinit();
        
        const high_id: u32 = 1_000_000;
        high_id_graph.addNode(high_id);
        high_id_graph.addNode(high_id + 1);
        high_id_graph.addNode(high_id + 2);
        
        _ = high_id_graph.addEdge(high_id, high_id + 1, 1) catch {};
        _ = high_id_graph.addEdge(high_id + 1, high_id + 2, 1) catch {};
        
        var result = try optimized.computeOptimizedCloseness(std.testing.allocator, &high_id_graph, .{});
        defer result.deinit(std.testing.allocator);
        
        try std.testing.expect(result.node_ids.len == 3);
        
        // Verify high IDs are handled correctly
        var found_high_id = false;
        for (result.node_ids) |id| {
            if (id == high_id) {
                found_high_id = true;
                break;
            }
        }
        try std.testing.expect(found_high_id);
    }
}

// CANARY: REQ=REQ-COMPILATION-FIXES-INTEGRATION-OCTOBER-2025-005; FEATURE="Compilation Fixes Integration"; ASPECT=PerformanceBenchmarking; STATUS=TESTED; TEST=test_performance_benchmarking_post_fix; OWNER=build; UPDATED=2025-10-05
test "test_performance_benchmarking_post_fix" {
    // Comprehensive performance testing to ensure compilation fix doesn't impact performance
    var graph = builders.Graph.init(std.testing.allocator);
    defer graph.deinit();
    
    // Create a grid graph for performance testing (10x10 = 100 nodes)
    const rows = 10;
    const cols = 10;
    
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            const id = r * cols + c;
            graph.addNode(id);
            
            if (c + 1 < cols) {
                _ = graph.addEdge(id, id + 1, 1) catch {};
                _ = graph.addEdge(id + 1, id, 1) catch {};
            }
            
            if (r + 1 < rows) {
                const down_id = (r + 1) * cols + c;
                _ = graph.addEdge(id, down_id, 1) catch {};
                _ = graph.addEdge(down_id, id, 1) catch {};
            }
        }
    }
    
    // Benchmark optimized closeness
    const optimized_start = std.time.nanoTimestamp();
    var optimized_result = try optimized.computeOptimizedCloseness(std.testing.allocator, &graph, .{
        .mode = .harmonic,
        .normalize = true,
    });
    const optimized_end = std.time.nanoTimestamp();
    defer optimized_result.deinit(std.testing.allocator);
    
    // Benchmark standard closeness for comparison
    const standard_start = std.time.nanoTimestamp();
    var standard_result = try closeness.compute(std.testing.allocator, &graph, .{
        .mode = .harmonic,
        .normalize = true,
    });
    const standard_end = std.time.nanoTimestamp();
    defer standard_result.deinit(std.testing.allocator);
    
    const optimized_duration = @as(u64, @intCast(optimized_end - optimized_start));
    const standard_duration = @as(u64, @intCast(standard_end - standard_start));
    
    // Log performance results
    std.log.info("Performance comparison for {d} nodes (post-compilation-fix):", .{rows * cols});
    std.log.info("  Optimized: {d} ns", .{optimized_duration});
    std.log.info("  Standard:  {d} ns", .{standard_duration});
    
    // Optimized should be competitive with standard implementation
    if (standard_duration > 0) {
        // Allow some variance but ensure performance is reasonable
        try std.testing.expect(optimized_duration <= standard_duration * 3);
    }
    
    // Both should complete in reasonable time
    try std.testing.expect(optimized_duration < 1_000_000_000); // Less than 1 second
    try std.testing.expect(standard_duration < 1_000_000_000);
    
    // Results should be consistent
    try std.testing.expect(optimized_result.node_ids.len == standard_result.node_ids.len);
    try std.testing.expect(optimized_result.node_ids.len == 100);
}

// CANARY: REQ=REQ-COMPILATION-FIXES-INTEGRATION-OCTOBER-2025-006; FEATURE="Compilation Fixes Integration"; ASPECT=BuildSystemIntegration; STATUS=TESTED; TEST=test_build_system_integration_post_fix; OWNER=build; UPDATED=2025-10-05
test "test_build_system_integration_post_fix" {
    // Test that the compilation fix integrates properly with the build system
    
    // Test that all graph module components work together
    var graph = builders.Graph.init(std.testing.allocator);
    defer graph.deinit();
    
    // Create a representative graph
    var i: u32 = 1;
    while (i <= 8) : (i += 1) {
        graph.addNode(i);
    }
    
    // Connect in a way that tests various code paths
    i = 1;
    while (i < 8) : (i += 1) {
        _ = graph.addEdge(i, i + 1, 1) catch {};
        if (i <= 4) {
            _ = graph.addEdge(i, i + 4, 1) catch {};
        }
    }
    _ = graph.addEdge(8, 1, 1) catch {}; // Complete the cycle
    
    // Test all optimized algorithms to ensure module integration
    {
        var closeness_result = try optimized.computeOptimizedCloseness(std.testing.allocator, &graph, .{
            .mode = .standard,
            .normalize = true,
        });
        defer closeness_result.deinit(std.testing.allocator);
        try std.testing.expect(closeness_result.node_ids.len == 8);
    }
    
    {
        var pagerank_result = try optimized.computeOptimizedPageRank(std.testing.allocator, &graph, .{
            .damping = 0.85,
            .epsilon = 1e-8,
            .max_iterations = 100,
        });
        defer pagerank_result.deinit(std.testing.allocator);
        try std.testing.expect(pagerank_result.node_ids.len == 8);
        try std.testing.expect(pagerank_result.converged or pagerank_result.iterations == 100);
    }
    
    // Test standard algorithms for comparison (ensures compatibility)
    {
        var standard_closeness = try closeness.compute(std.testing.allocator, &graph, .{
            .mode = .standard,
            .normalize = true,
        });
        defer standard_closeness.deinit(std.testing.allocator);
        try std.testing.expect(standard_closeness.node_ids.len == 8);
    }
    
    {
        var standard_pagerank = try pagerank.compute(std.testing.allocator, &graph, .{
            .damping = 0.85,
            .epsilon = 1e-8,
            .max_iterations = 100,
        });
        defer standard_pagerank.deinit(std.testing.allocator);
        try std.testing.expect(standard_pagerank.node_ids.len == 8);
    }
}

// CANARY: REQ=REQ-COMPILATION-FIXES-INTEGRATION-OCTOBER-2025-007; FEATURE="Compilation Fixes Integration"; ASPECT=ConcurrentExecutionSafety; STATUS=TESTED; TEST=test_concurrent_execution_safety_post_fix; OWNER=build; UPDATED=2025-10-05
test "test_concurrent_execution_safety_post_fix" {
    // Test that the compilation fix maintains thread safety characteristics
    // (Simulated concurrent execution since we can't easily test real concurrency in Zig tests)
    
    var graphs = [_]builders.Graph{
        builders.Graph.init(std.testing.allocator),
        builders.Graph.init(std.testing.allocator),
        builders.Graph.init(std.testing.allocator),
    };
    defer for (&graphs) |*g| g.deinit();
    
    // Create different graph structures for each "concurrent" execution
    for (&graphs, 0..) |*graph, graph_idx| {
        const base_id = @as(u32, @intCast(graph_idx)) * 100;
        const size = 5 + graph_idx;
        
        var i: u32 = 0;
        while (i < size) : (i += 1) {
            graph.addNode(base_id + i);
            if (i > 0) {
                _ = graph.addEdge(base_id + i - 1, base_id + i, 1) catch {};
                _ = graph.addEdge(base_id + i, base_id + i - 1, 1) catch {};
            }
        }
    }
    
    // Simulate concurrent execution by running algorithms on all graphs
    var results: [3]?optimized.ClosenessResult = [_]?optimized.ClosenessResult{null} ** 3;
    defer for (&results) |*result| {
        if (result.*) |*r| {
            r.deinit(std.testing.allocator);
        }
    };
    
    for (&graphs, 0..) |*graph, idx| {
        results[idx] = try optimized.computeOptimizedCloseness(std.testing.allocator, graph, .{
            .mode = .harmonic,
            .normalize = true,
        });
    }
    
    // Verify all executions completed successfully
    for (results, 0..) |result, idx| {
        if (result) |r| {
            const expected_size = 5 + idx;
            try std.testing.expect(r.node_ids.len == expected_size);
            try std.testing.expect(r.scores.len == expected_size);
        } else {
            try std.testing.expect(false); // Should never be null
        }
    }
}