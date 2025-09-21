const std = @import("std");
const flow = @import("../src/graph/flow_edmonds_karp.zig");
const builders = @import("../src/graph/builders.zig");

test "TestCANARY_REQ_GQL_066_EdmondsKarp edge cases" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    try g.addNode(1);
    try g.addNode(2);
    try g.rebuildIndex(std.testing.allocator);
    const f0 = try flow.maxFlow(std.testing.allocator, &g, 1, 2);
    try std.testing.expect(f0 == 0);
    try g.addEdge(1, 2, 7);
    try g.rebuildIndex(std.testing.allocator);
    const f1 = try flow.maxFlow(std.testing.allocator, &g, 1, 2);
    try std.testing.expect(f1 == 7);
}
