const std = @import("std");
const builders = @import("../src/graph/builders.zig");
const prim = @import("../src/graph/spanning_prim.zig");
const kruskal = @import("../src/graph/spanning_kruskal.zig");

test "TestCANARY_REQ_GQL_065_Prim" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Create a graph with two components to verify forest handling & equivalence per component.
    // Component 1: 1-2 (1), 2-3 (2), 1-3 (5)
    g.addNode(1);
    g.addNode(2);
    g.addNode(3);
    _ = g.addEdge(1, 2, 1) catch {};
    _ = g.addEdge(2, 3, 2) catch {};
    _ = g.addEdge(1, 3, 5) catch {};
    // Component 2: 10-11 (3)
    g.addNode(10);
    g.addNode(11);
    _ = g.addEdge(10, 11, 3) catch {};

    var prim_res = try prim.compute(std.testing.allocator, &g);
    defer prim_res.deinit(std.testing.allocator);
    var kruskal_res = try kruskal.compute(std.testing.allocator, &g);
    defer kruskal_res.deinit(std.testing.allocator);

    try std.testing.expect(prim_res.forest and kruskal_res.forest);
    // Each component MST weight: comp1 = 3, comp2 = 3 -> total 6
    try std.testing.expectApproxEqAbs(6.0, prim_res.total_weight, 0.0001);
    try std.testing.expectApproxEqAbs(kruskal_res.total_weight, prim_res.total_weight, 0.0001);
    // Edge counts: comp1 2 + comp2 1 = 3
    try std.testing.expect(prim_res.edges.len == 3);
}
