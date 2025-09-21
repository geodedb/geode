const std = @import("std");
const bfs_mod = @import("../graph/traversal_bfs.zig");
const builders = @import("../graph/builders.zig");

test "TestCANARY_REQ_GQL_062_BFS_EdgeCases" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    try g.addNode(10);
    try g.addNode(11);
    try g.addEdge(10, 11, 1);
    try g.rebuildIndex(std.testing.allocator);
    const order = try bfs_mod.BFS.traverse(std.testing.allocator, &g, 10);
    defer std.testing.allocator.free(order);
    try std.testing.expectEqual(@as(usize, 2), order.len);
    try std.testing.expect(order[0] == 10 and order[1] == 11);
}
