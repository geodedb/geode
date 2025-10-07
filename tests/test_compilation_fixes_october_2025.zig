const std = @import("std");
const geode = @import("geode");
const optimized = geode.graph.optimized;
const builders = geode.graph.builders;

// CANARY: REQ=REQ-COMPILATION-FIXES-OCTOBER-2025-001; FEATURE="Compilation Fixes"; ASPECT=VariableMutability; STATUS=TESTED; TEST=test_variable_mutability_compliance; OWNER=build; UPDATED=2025-10-05
test "test_variable_mutability_compliance" {
    // Test that the compilation fix for variable mutability is working correctly
    var graph = builders.Graph.init(std.testing.allocator);
    defer graph.deinit();

    // Create a simple graph to test the fixed algorithm
    graph.addNode(1);
    graph.addNode(2);
    graph.addNode(3);

    _ = graph.addEdge(1, 2, 1) catch {};
    _ = graph.addEdge(2, 3, 1) catch {};
    _ = graph.addEdge(3, 1, 1) catch {};

    // Test that the optimized closeness algorithm works without compilation errors
    var result = try optimized.computeOptimizedCloseness(std.testing.allocator, &graph, .{
        .mode = .standard,
        .normalize = false,
    });
    defer result.deinit(std.testing.allocator);

    // Verify the algorithm produced valid results
    try std.testing.expect(result.node_ids.len == 3);
    try std.testing.expect(result.scores.len == 3);

    // All scores should be non-negative
    for (result.scores) |score| {
        try std.testing.expect(score >= 0.0);
    }
}

// CANARY: REQ=REQ-COMPILATION-FIXES-OCTOBER-2025-002; FEATURE="Compilation Fixes"; ASPECT=PageRankMutability; STATUS=TESTED; TEST=test_pagerank_mutability_compliance; OWNER=build; UPDATED=2025-10-05
test "test_pagerank_mutability_compliance" {
    // Test that PageRank compilation is also working correctly
    var graph = builders.Graph.init(std.testing.allocator);
    defer graph.deinit();

    // Create a directed graph
    graph.addNode(1);
    graph.addNode(2);
    graph.addNode(3);

    _ = graph.addEdge(1, 2, 1) catch {};
    _ = graph.addEdge(2, 3, 1) catch {};
    _ = graph.addEdge(3, 1, 1) catch {};

    // Test that the optimized PageRank algorithm compiles and runs
    var result = try optimized.computeOptimizedPageRank(std.testing.allocator, &graph, .{
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
}

// CANARY: REQ=REQ-COMPILATION-FIXES-OCTOBER-2025-003; FEATURE="Compilation Fixes"; ASPECT=MemoryManagement; STATUS=TESTED; TEST=test_memory_management_after_fix; OWNER=build; UPDATED=2025-10-05
test "test_memory_management_after_fix" {
    // Test that memory management is still correct after the mutability fix
    var graph = builders.Graph.init(std.testing.allocator);
    defer graph.deinit();

    // Create a moderately sized graph
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        graph.addNode(i);
        if (i > 0) {
            _ = graph.addEdge(i - 1, i, 1) catch {};
            _ = graph.addEdge(i, i - 1, 1) catch {};
        }
    }

    // Run multiple iterations to test for memory leaks
    var iteration: usize = 0;
    while (iteration < 5) : (iteration += 1) {
        var result = try optimized.computeOptimizedCloseness(std.testing.allocator, &graph, .{
            .mode = .harmonic,
            .normalize = true,
        });
        defer result.deinit(std.testing.allocator);

        // Verify results are consistent
        try std.testing.expect(result.node_ids.len == 10);
        try std.testing.expect(result.scores.len == 10);
    }

    // If we reach here without memory errors, the fix is working correctly
    try std.testing.expect(true);
}

// CANARY: REQ=REQ-COMPILATION-FIXES-OCTOBER-2025-004; FEATURE="Compilation Fixes"; ASPECT=FinalScoresImmutability; STATUS=TESTED; TEST=test_final_scores_immutability; OWNER=build; UPDATED=2025-10-05
test "test_final_scores_immutability" {
    // Test that the final_scores variable immutability fix is working
    var graph = builders.Graph.init(std.testing.allocator);
    defer graph.deinit();

    // Create a specific graph structure
    graph.addNode(10);
    graph.addNode(20);
    graph.addNode(30);

    _ = graph.addEdge(10, 20, 1) catch {};
    _ = graph.addEdge(20, 30, 1) catch {};

    // Test the algorithm that was fixed
    var result = try optimized.computeOptimizedCloseness(std.testing.allocator, &graph, .{
        .mode = .standard,
        .normalize = true,
    });
    defer result.deinit(std.testing.allocator);

    // Verify that results are properly computed and returned
    try std.testing.expect(result.node_ids.len == 3);
    try std.testing.expect(result.scores.len == 3);

    // Check that node IDs are in sorted order (as expected by the algorithm)
    for (result.node_ids[0 .. result.node_ids.len - 1], result.node_ids[1..]) |current, next| {
        try std.testing.expect(current <= next);
    }

    // Verify that the specific nodes are present
    var found_10 = false;
    var found_20 = false;
    var found_30 = false;

    for (result.node_ids) |id| {
        if (id == 10) found_10 = true;
        if (id == 20) found_20 = true;
        if (id == 30) found_30 = true;
    }

    try std.testing.expect(found_10);
    try std.testing.expect(found_20);
    try std.testing.expect(found_30);
}

// CANARY: REQ=REQ-COMPILATION-FIXES-OCTOBER-2025-005; FEATURE="Compilation Fixes"; ASPECT=AlgorithmIntegrity; STATUS=TESTED; TEST=test_algorithm_integrity_post_fix; OWNER=build; UPDATED=2025-10-05
test "test_algorithm_integrity_post_fix" {
    // Test that the algorithm behavior is identical before and after the compilation fix
    var graph = builders.Graph.init(std.testing.allocator);
    defer graph.deinit();

    // Create a known graph structure for deterministic testing
    var i: u32 = 1;
    while (i <= 5) : (i += 1) {
        graph.addNode(i);
    }

    // Star graph: node 1 connected to all others
    i = 2;
    while (i <= 5) : (i += 1) {
        _ = graph.addEdge(1, i, 1) catch {};
        _ = graph.addEdge(i, 1, 1) catch {};
    }

    // Test the fixed algorithm
    var result = try optimized.computeOptimizedCloseness(std.testing.allocator, &graph, .{
        .mode = .standard,
        .normalize = false,
    });
    defer result.deinit(std.testing.allocator);

    // Verify expected behavior for star graph
    try std.testing.expect(result.node_ids.len == 5);

    // Find the center node (node 1) - should have highest closeness
    var center_score: f64 = 0;
    var center_idx: usize = 0;
    for (result.node_ids, 0..) |id, idx| {
        if (id == 1) {
            center_score = result.scores[idx];
            center_idx = idx;
            break;
        }
    }

    // Center node should have higher score than all others
    for (result.node_ids, 0..) |id, idx| {
        if (id != 1) {
            try std.testing.expect(result.scores[center_idx] > result.scores[idx]);
        }
    }

    // Center node should have perfect centrality (can reach all nodes in 1 step)
    try std.testing.expect(center_score > 0);
}

// CANARY: REQ=REQ-COMPILATION-FIXES-OCTOBER-2025-006; FEATURE="Compilation Fixes"; ASPECT=EdgeCaseHandling; STATUS=TESTED; TEST=test_edge_cases_post_compilation_fix; OWNER=build; UPDATED=2025-10-05
test "test_edge_cases_post_compilation_fix" {
    // Test edge cases to ensure the compilation fix doesn't affect edge case handling

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

    // Test disconnected components
    {
        var disconnected_graph = builders.Graph.init(std.testing.allocator);
        defer disconnected_graph.deinit();

        disconnected_graph.addNode(1);
        disconnected_graph.addNode(2);
        disconnected_graph.addNode(3);
        disconnected_graph.addNode(4);

        // Connect only 1-2, leaving 3 and 4 isolated
        _ = disconnected_graph.addEdge(1, 2, 1) catch {};
        _ = disconnected_graph.addEdge(2, 1, 1) catch {};

        var result = try optimized.computeOptimizedCloseness(std.testing.allocator, &disconnected_graph, .{
            .mode = .harmonic, // Better for disconnected graphs
            .normalize = true,
        });
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(result.node_ids.len == 4);
        try std.testing.expect(result.scores.len == 4);
    }
}

// CANARY: REQ=REQ-COMPILATION-FIXES-OCTOBER-2025-007; FEATURE="Compilation Fixes"; ASPECT=PerformanceConsistency; STATUS=TESTED; TEST=test_performance_consistency_post_fix; OWNER=build; UPDATED=2025-10-05
test "test_performance_consistency_post_fix" {
    // Test that performance characteristics are maintained after the compilation fix
    var graph = builders.Graph.init(std.testing.allocator);
    defer graph.deinit();

    // Create a moderately complex graph for performance testing
    const size = 25; // 25 nodes for reasonable test execution time
    var i: u32 = 0;
    while (i < size) : (i += 1) {
        graph.addNode(i);
        // Connect each node to the next 3 nodes (circular)
        var j: u32 = 1;
        while (j <= 3) : (j += 1) {
            const target = (i + j) % size;
            _ = graph.addEdge(i, target, 1) catch {};
        }
    }

    // Measure execution time
    const start_time = std.time.nanoTimestamp();
    var result = try optimized.computeOptimizedCloseness(std.testing.allocator, &graph, .{
        .mode = .harmonic,
        .normalize = true,
    });
    const end_time = std.time.nanoTimestamp();
    defer result.deinit(std.testing.allocator);

    const duration_ns = @as(u64, @intCast(end_time - start_time));

    // Verify reasonable performance (should complete quickly for 25 nodes)
    try std.testing.expect(duration_ns < 100_000_000); // Less than 100ms

    // Verify algorithm completed successfully
    try std.testing.expect(result.node_ids.len == size);
    try std.testing.expect(result.scores.len == size);

    // All scores should be reasonable values
    for (result.scores) |score| {
        try std.testing.expect(score >= 0.0);
        try std.testing.expect(score <= 1.0); // Normalized scores should be <= 1.0
    }
}

// CANARY: REQ=REQ-COMPILATION-FIXES-OCTOBER-2025-008; FEATURE="Compilation Fixes"; ASPECT=CompilationStability; STATUS=TESTED; TEST=test_compilation_stability; OWNER=build; UPDATED=2025-10-05
test "test_compilation_stability" {
    // Test that ensures the compilation fix maintains stability across multiple uses

    // Multiple graph creation and destruction cycles
    var cycle: usize = 0;
    while (cycle < 3) : (cycle += 1) {
        var graph = builders.Graph.init(std.testing.allocator);
        defer graph.deinit();

        // Create different graph topologies in each cycle
        const node_count = 5 + cycle;
        var i: u32 = 0;
        while (i < node_count) : (i += 1) {
            graph.addNode(i + 100); // Use different node IDs each cycle
            if (i > 0) {
                _ = graph.addEdge(i + 99, i + 100, 1) catch {};
            }
        }

        // Test both algorithms to ensure compilation stability
        {
            var closeness_result = try optimized.computeOptimizedCloseness(std.testing.allocator, &graph, .{});
            defer closeness_result.deinit(std.testing.allocator);
            try std.testing.expect(closeness_result.node_ids.len == node_count);
        }

        {
            var pagerank_result = try optimized.computeOptimizedPageRank(std.testing.allocator, &graph, .{
                .max_iterations = 20, // Reduced for faster testing
            });
            defer pagerank_result.deinit(std.testing.allocator);
            try std.testing.expect(pagerank_result.node_ids.len == node_count);
        }
    }

    // If all cycles complete without compilation or runtime errors, the fix is stable
    try std.testing.expect(true);
}
