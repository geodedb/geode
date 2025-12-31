const std = @import("std");
const builders = @import("builders.zig");
const tarjan = @import("connectivity_tarjan_scc.zig");

// CANARY: REQ=REQ-GQL-064; FEATURE="Connectivity"; ASPECT=SCC_WRAPPER; STATUS=IMPL; OWNER=graph; UPDATED=2025-12-30

/// Compute strongly connected components using Tarjan's algorithm.
/// Takes adjacency list format (graph[i] = array of neighbors of node i).
/// Returns component assignment array where result[i] = component ID of node i.
pub fn compute(allocator: std.mem.Allocator, graph: [][]u32) ![]u32 {
    // Convert adjacency list to builders.Graph format
    var g = builders.Graph.init(allocator);
    defer g.deinit();

    // Add all nodes
    for (0..graph.len) |i| {
        g.addNode(@intCast(i));
    }

    // Add all edges (unweighted, using weight 1.0)
    for (graph, 0..) |neighbors, src| {
        for (neighbors) |dst| {
            try g.addEdge(@intCast(src), dst, 1.0);
        }
    }

    // Call production Tarjan implementation
    var result = try tarjan.compute(allocator, g);
    defer result.deinit(allocator);

    // Convert SccResult to flat component array
    // result.components is [][]u32 where each inner array is a component
    const components = try allocator.alloc(u32, graph.len);
    @memset(components, 0); // Default component ID

    // Assign component IDs: iterate through components and assign ID to each node
    for (result.components, 0..) |component, comp_id| {
        for (component) |node_id| {
            if (node_id < graph.len) {
                components[node_id] = @intCast(comp_id);
            }
        }
    }

    return components;
}

test "compute scc - single component" {
    const allocator = std.testing.allocator;

    // Cycle: 0 -> 1 -> 2 -> 0 (single SCC)
    var graph: [3][]u32 = undefined;
    var n0 = [_]u32{1};
    var n1 = [_]u32{2};
    var n2 = [_]u32{0};
    graph[0] = &n0;
    graph[1] = &n1;
    graph[2] = &n2;

    const result = try compute(allocator, &graph);
    defer allocator.free(result);

    // All nodes should be in the same component
    try std.testing.expectEqual(result[0], result[1]);
    try std.testing.expectEqual(result[1], result[2]);
}

test "compute scc - multiple components" {
    const allocator = std.testing.allocator;

    // Two separate components: 0 -> 1 and 2 -> 3
    var graph: [4][]u32 = undefined;
    var n0 = [_]u32{1};
    var n1 = [_]u32{};
    var n2 = [_]u32{3};
    var n3 = [_]u32{};
    graph[0] = &n0;
    graph[1] = &n1;
    graph[2] = &n2;
    graph[3] = &n3;

    const result = try compute(allocator, &graph);
    defer allocator.free(result);

    // 0 and 1 should be in different components (no cycle)
    // 2 and 3 should be in different components (no cycle)
    try std.testing.expect(result[0] != result[1]);
    try std.testing.expect(result[2] != result[3]);
}

test "compute scc - empty graph" {
    const allocator = std.testing.allocator;
    var graph: [0][]u32 = .{};

    const result = try compute(allocator, &graph);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}
