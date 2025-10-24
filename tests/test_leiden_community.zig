// Comprehensive test suite for Leiden community detection
// CANARY: REQ=REQ-GQL-LEIDEN-TEST; FEATURE="Leiden Test Suite"; ASPECT=Testing; STATUS=TESTED; TEST=TestCANARY_Leiden_Suite; OWNER=test; UPDATED=2025-09-29

const std = @import("std");
const testing = std.testing;
const lib = @import("geode");
const leiden = lib.graph.leiden;

test "TestCANARY_Leiden_Suite simple communities" {
    const allocator = testing.allocator;

    var detector = leiden.LeidenDetector.init(allocator, 1.0);

    // Create two clear communities with weak link
    const nodes = [_]u64{ 0, 1, 2, 3, 4, 5 };
    const edges = [_]leiden.LeidenDetector.Edge{
        // Community 1: 0, 1, 2 (strongly connected)
        .{ .source = 0, .target = 1, .weight = 10.0 },
        .{ .source = 0, .target = 2, .weight = 10.0 },
        .{ .source = 1, .target = 2, .weight = 10.0 },
        // Community 2: 3, 4, 5 (strongly connected)
        .{ .source = 3, .target = 4, .weight = 10.0 },
        .{ .source = 3, .target = 5, .weight = 10.0 },
        .{ .source = 4, .target = 5, .weight = 10.0 },
        // Weak inter-community link
        .{ .source = 2, .target = 3, .weight = 0.1 },
    };

    const graph = leiden.LeidenDetector.Graph{
        .nodes = &nodes,
        .edges = &edges,
        .node_weights = null,
    };

    const result = try detector.detectCommunities(graph);
    defer {
        for (result.communities) |*comm| {
            comm.nodes.deinit();
        }
        allocator.free(result.communities);
    }

    // Should detect 2 communities
    try testing.expect(result.communities.len >= 2);
    try testing.expect(result.modularity > 0.5);
}

test "TestCANARY_Leiden_Suite single community" {
    const allocator = testing.allocator;

    var detector = leiden.LeidenDetector.init(allocator, 1.0);

    // Fully connected graph - should be one community
    const nodes = [_]u64{ 0, 1, 2, 3 };
    const edges = [_]leiden.LeidenDetector.Edge{
        .{ .source = 0, .target = 1, .weight = 1.0 },
        .{ .source = 0, .target = 2, .weight = 1.0 },
        .{ .source = 0, .target = 3, .weight = 1.0 },
        .{ .source = 1, .target = 2, .weight = 1.0 },
        .{ .source = 1, .target = 3, .weight = 1.0 },
        .{ .source = 2, .target = 3, .weight = 1.0 },
    };

    const graph = leiden.LeidenDetector.Graph{
        .nodes = &nodes,
        .edges = &edges,
        .node_weights = null,
    };

    const result = try detector.detectCommunities(graph);
    defer {
        for (result.communities) |*comm| {
            comm.nodes.deinit();
        }
        allocator.free(result.communities);
    }

    // Fully connected should stay as one or few communities
    try testing.expect(result.communities.len <= 2);
}

test "TestCANARY_Leiden_Suite hierarchical structure" {
    const allocator = testing.allocator;

    var detector = leiden.LeidenDetector.init(allocator, 1.0);

    // Create hierarchical community structure
    const nodes = [_]u64{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    var edges = std.ArrayList(leiden.LeidenDetector.Edge).init(allocator);
    defer edges.deinit();

    // Level 1: three groups
    // Group A: 0, 1, 2
    try edges.append(.{ .source = 0, .target = 1, .weight = 5.0 });
    try edges.append(.{ .source = 1, .target = 2, .weight = 5.0 });
    try edges.append(.{ .source = 0, .target = 2, .weight = 5.0 });

    // Group B: 3, 4, 5
    try edges.append(.{ .source = 3, .target = 4, .weight = 5.0 });
    try edges.append(.{ .source = 4, .target = 5, .weight = 5.0 });
    try edges.append(.{ .source = 3, .target = 5, .weight = 5.0 });

    // Group C: 6, 7, 8
    try edges.append(.{ .source = 6, .target = 7, .weight = 5.0 });
    try edges.append(.{ .source = 7, .target = 8, .weight = 5.0 });
    try edges.append(.{ .source = 6, .target = 8, .weight = 5.0 });

    // Level 2: Groups A and B are weakly connected
    try edges.append(.{ .source = 2, .target = 3, .weight = 1.0 });

    const graph = leiden.LeidenDetector.Graph{
        .nodes = &nodes,
        .edges = edges.items,
        .node_weights = null,
    };

    const result = try detector.detectCommunities(graph);
    defer {
        for (result.communities) |*comm| {
            comm.nodes.deinit();
        }
        allocator.free(result.communities);
    }

    // Should detect 2 or 3 communities
    try testing.expect(result.communities.len >= 2);
    try testing.expect(result.communities.len <= 3);
}

test "TestCANARY_Leiden_Suite different resolutions" {
    const allocator = testing.allocator;

    const nodes = [_]u64{ 0, 1, 2, 3, 4, 5 };
    const edges = [_]leiden.LeidenDetector.Edge{
        .{ .source = 0, .target = 1, .weight = 2.0 },
        .{ .source = 1, .target = 2, .weight = 2.0 },
        .{ .source = 2, .target = 3, .weight = 2.0 },
        .{ .source = 3, .target = 4, .weight = 2.0 },
        .{ .source = 4, .target = 5, .weight = 2.0 },
        .{ .source = 5, .target = 0, .weight = 2.0 },
    };

    const graph = leiden.LeidenDetector.Graph{
        .nodes = &nodes,
        .edges = &edges,
        .node_weights = null,
    };

    // Test with low resolution (fewer communities)
    var detector_low = leiden.LeidenDetector.init(allocator, 0.5);
    const result_low = try detector_low.detectCommunities(graph);
    defer {
        for (result_low.communities) |*comm| {
            comm.nodes.deinit();
        }
        allocator.free(result_low.communities);
    }

    // Test with high resolution (more communities)
    var detector_high = leiden.LeidenDetector.init(allocator, 2.0);
    const result_high = try detector_high.detectCommunities(graph);
    defer {
        for (result_high.communities) |*comm| {
            comm.nodes.deinit();
        }
        allocator.free(result_high.communities);
    }

    // Higher resolution should produce more communities
    try testing.expect(result_high.communities.len >= result_low.communities.len);
}

test "TestCANARY_Leiden_Suite isolated nodes" {
    const allocator = testing.allocator;

    var detector = leiden.LeidenDetector.init(allocator, 1.0);

    // Graph with isolated nodes
    const nodes = [_]u64{ 0, 1, 2, 3, 4, 5 };
    const edges = [_]leiden.LeidenDetector.Edge{
        .{ .source = 0, .target = 1, .weight = 1.0 },
        .{ .source = 2, .target = 3, .weight = 1.0 },
        // Nodes 4 and 5 are isolated
    };

    const graph = leiden.LeidenDetector.Graph{
        .nodes = &nodes,
        .edges = &edges,
        .node_weights = null,
    };

    const result = try detector.detectCommunities(graph);
    defer {
        for (result.communities) |*comm| {
            comm.nodes.deinit();
        }
        allocator.free(result.communities);
    }

    // Each isolated node should be its own community
    try testing.expect(result.communities.len >= 4);
}

test "TestCANARY_Leiden_Suite weighted edges" {
    const allocator = testing.allocator;

    var detector = leiden.LeidenDetector.init(allocator, 1.0);

    // Test with varying edge weights
    const nodes = [_]u64{ 0, 1, 2, 3 };
    const edges = [_]leiden.LeidenDetector.Edge{
        .{ .source = 0, .target = 1, .weight = 100.0 }, // Strong connection
        .{ .source = 1, .target = 2, .weight = 0.01 }, // Very weak
        .{ .source = 2, .target = 3, .weight = 100.0 }, // Strong connection
    };

    const graph = leiden.LeidenDetector.Graph{
        .nodes = &nodes,
        .edges = &edges,
        .node_weights = null,
    };

    const result = try detector.detectCommunities(graph);
    defer {
        for (result.communities) |*comm| {
            comm.nodes.deinit();
        }
        allocator.free(result.communities);
    }

    // Should detect 2 communities: {0,1} and {2,3}
    try testing.expect(result.communities.len == 2);
}

test "TestCANARY_Leiden_Suite self loops" {
    const allocator = testing.allocator;

    var detector = leiden.LeidenDetector.init(allocator, 1.0);

    // Graph with self-loops
    const nodes = [_]u64{ 0, 1, 2 };
    const edges = [_]leiden.LeidenDetector.Edge{
        .{ .source = 0, .target = 0, .weight = 1.0 }, // Self-loop
        .{ .source = 0, .target = 1, .weight = 1.0 },
        .{ .source = 1, .target = 1, .weight = 1.0 }, // Self-loop
        .{ .source = 1, .target = 2, .weight = 1.0 },
    };

    const graph = leiden.LeidenDetector.Graph{
        .nodes = &nodes,
        .edges = &edges,
        .node_weights = null,
    };

    const result = try detector.detectCommunities(graph);
    defer {
        for (result.communities) |*comm| {
            comm.nodes.deinit();
        }
        allocator.free(result.communities);
    }

    // Should handle self-loops gracefully
    try testing.expect(result.communities.len >= 1);
    try testing.expect(result.modularity >= 0);
}

test "TestCANARY_Leiden_Suite large graph performance" {
    const allocator = testing.allocator;

    var detector = leiden.LeidenDetector.init(allocator, 1.0);
    detector.max_iterations = 10; // Limit iterations for test speed

    // Generate a larger graph
    var nodes = std.ArrayList(u64).init(allocator);
    defer nodes.deinit();
    var edges = std.ArrayList(leiden.LeidenDetector.Edge).init(allocator);
    defer edges.deinit();

    const num_nodes: u64 = 100;
    const num_communities: u64 = 5;
    const nodes_per_community = num_nodes / num_communities;

    // Create nodes
    var i: u64 = 0;
    while (i < num_nodes) : (i += 1) {
        try nodes.append(i);
    }

    // Create communities with dense internal connections
    var c: u64 = 0;
    while (c < num_communities) : (c += 1) {
        const start = c * nodes_per_community;
        const end = start + nodes_per_community;

        var n1 = start;
        while (n1 < end) : (n1 += 1) {
            var n2 = n1 + 1;
            while (n2 < end) : (n2 += 2) { // Not fully connected to keep it manageable
                try edges.append(.{ .source = n1, .target = n2, .weight = 10.0 });
            }
        }
    }

    // Add weak inter-community edges
    c = 0;
    while (c < num_communities - 1) : (c += 1) {
        const n1 = c * nodes_per_community;
        const n2 = (c + 1) * nodes_per_community;
        try edges.append(.{ .source = n1, .target = n2, .weight = 0.1 });
    }

    const graph = leiden.LeidenDetector.Graph{
        .nodes = nodes.items,
        .edges = edges.items,
        .node_weights = null,
    };

    const start_time = std.time.milliTimestamp();
    const result = try detector.detectCommunities(graph);
    const elapsed = std.time.milliTimestamp() - start_time;
    defer {
        for (result.communities) |*comm| {
            comm.nodes.deinit();
        }
        allocator.free(result.communities);
    }

    // Should complete in reasonable time
    try testing.expect(elapsed < 5000); // Less than 5 seconds
    try testing.expect(result.communities.len >= 3); // Should find some communities
    try testing.expect(result.communities.len <= 10); // But not too fragmented
}
