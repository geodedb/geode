const std = @import("std");
const builders = @import("../src/graph/builders.zig");
const kruskal = @import("../src/graph/spanning_kruskal.zig");

test "TestCANARY_REQ_GQL_065_Kruskal" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Known graph (square with diagonal) to test MST selection.
    // 1-2 (1), 2-3 (2), 3-4 (1), 4-1 (2), 1-3 (2.5)
    g.addNode(1);
    g.addNode(2);
    g.addNode(3);
    g.addNode(4);
    _ = g.addEdge(1, 2, 1) catch {};
    _ = g.addEdge(2, 3, 2) catch {};
    _ = g.addEdge(3, 4, 1) catch {};
    _ = g.addEdge(4, 1, 2) catch {};
    _ = g.addEdge(1, 3, 2.5) catch {};
    var res = try kruskal.compute(std.testing.allocator, &g);
    defer res.deinit(std.testing.allocator);
    // Expected MST edges total weight = 1 + 1 + 2 = 4
    try std.testing.expectApproxEqAbs(4.0, res.total_weight, 0.0001);
    try std.testing.expect(res.edges.len == 3);
    try std.testing.expect(!res.forest);
}
