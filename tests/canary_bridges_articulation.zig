const std = @import("std");
const builders = @import("../src/graph/builders.zig");
const bridges_artic = @import("../src/graph/connectivity_bridges_articulation.zig");

// TestCANARY_REQ_GQL_064_BridgesArticulation
// Graph:
//   0 - 1 - 2 - 3
//       |   \
//       4    4
// Expected bridges: (0,1) and none of others (since 1-2 part of cycle with 2-4-1, 2-3 in chain? actually (2,3) is bridge)
// Articulation points: 1,2
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var g = try builders.Graph.init(alloc);
    defer g.deinit();
    for (0..5) |id| _ = try g.addNode(@as(u32, @intCast(id)));
    const add = struct {
        fn e(gr: *builders.Graph, a: u32, b: u32) !void {
            _ = try gr.addEdge(a, b);
            _ = try gr.addEdge(b, a);
        }
    };
    try add.e(&g, 0, 1);
    try add.e(&g, 1, 2);
    try add.e(&g, 2, 3);
    try add.e(&g, 1, 4);
    try add.e(&g, 2, 4);

    var res = try bridges_artic.compute(alloc, g);
    defer res.deinit(alloc);

    // Expect bridges: (0,1) and (2,3)
    try std.testing.expect(res.bridges.len == 2);
    try std.testing.expect(res.bridges[0].u == 0 and res.bridges[0].v == 1);
    try std.testing.expect(res.bridges[1].u == 2 and res.bridges[1].v == 3);

    // Articulation points 1 and 2
    try std.testing.expect(res.articulation.len == 2);
    try std.testing.expect(res.articulation[0] == 1);
    try std.testing.expect(res.articulation[1] == 2);
}
