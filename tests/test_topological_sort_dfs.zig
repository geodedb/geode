const std = @import("std");
const gmod = @import("../src/lib.zig");
const Graph = @import("../src/graph/builders.zig").Graph;

// TestCANARY_REQ_GQL_062_TopoDFS
// Validates topological ordering and cycle detection.

test "TestCANARY_REQ_GQL_062_TopoDFS basic and cycle" {
    var gpa = std.testing.allocator;
    // Basic DAG
    var g = try Graph.init(gpa, 6, .{});
    defer g.deinit(gpa);
    try g.addEdge(5, 2, 1);
    try g.addEdge(5, 0, 1);
    try g.addEdge(4, 0, 1);
    try g.addEdge(4, 1, 1);
    try g.addEdge(2, 3, 1);
    try g.addEdge(3, 1, 1);

    const order = try gmod.topo_dfs.topologicalSortDFS(gpa, &g);
    defer gpa.free(order);

    var pos = try gpa.alloc(usize, order.len);
    defer gpa.free(pos);
    for (order, 0..) |node, idx| pos[node] = idx;
    var it = g.edges.iterator();
    while (it.next()) |e| {
        try std.testing.expect(pos[e.src] < pos[e.dst]);
    }

    // Cycle detection
    var g2 = try Graph.init(gpa, 3, .{});
    defer g2.deinit(gpa);
    try g2.addEdge(0, 1, 1);
    try g2.addEdge(1, 2, 1);
    try g2.addEdge(2, 0, 1);
    const cyc = gmod.topo_dfs.topologicalSortDFS(gpa, &g2);
    try std.testing.expectError(error.CycleDetected, cyc);
}
