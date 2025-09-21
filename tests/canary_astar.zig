const std = @import("std");
const builders = @import("../src/graph/builders.zig");
const astar = @import("../src/graph/shortest_astar.zig");
const dijkstra = @import("../src/graph/shortest_dijkstra.zig");

test "TestCANARY_REQ_GQL_063_AStar" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Construct a weighted grid 5x5 to test heuristic guidance.
    const size: u32 = 5;
    var y: u32 = 0;
    while (y < size) : (y += 1) {
        var x: u32 = 0;
        while (x < size) : (x += 1) {
            const id = y * size + x;
            g.addNode(id);
        }
    }
    // Add 4-neighbor edges with weight 1
    y = 0;
    while (y < size) : (y += 1) {
        var x: u32 = 0;
        while (x < size) : (x += 1) {
            const id = y * size + x;
            if (x + 1 < size) {
                _ = g.addEdge(id, y * size + (x + 1), 1) catch {};
            }
            if (y + 1 < size) {
                _ = g.addEdge(id, (y + 1) * size + x, 1) catch {};
            }
        }
    }
    const start: u32 = 0;
    const goal: u32 = size * size - 1;
    const h = struct {
        pub fn h(v: u32, t: u32) f64 { // Manhattan distance heuristic
            const size_local: u32 = 5;
            const vx = v % size_local;
            const vy = v / size_local;
            const tx = t % size_local;
            const ty = t / size_local;
            const dx = if (vx > tx) vx - tx else tx - vx;
            const dy = if (vy > ty) vy - ty else ty - vy;
            return @as(f64, @floatFromInt(dx + dy));
        }
    }.h;
    var ares = try astar.compute(std.testing.allocator, g, start, goal, h);
    defer ares.deinit(std.testing.allocator);
    try std.testing.expect(ares.found);
    // Result distance should equal optimal path length ( (size-1)+(size-1) )
    try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt((size - 1) * 2)), ares.final_distance, 0.0001);
    // Cross-check vs Dijkstra
    var dres = try dijkstra.compute(std.testing.allocator, g, start, goal);
    defer dres.deinit(std.testing.allocator);
    var dist_map = std.AutoHashMap(u32, u64).init(std.testing.allocator);
    defer dist_map.deinit();
    var i: usize = 0;
    while (i < dres.order.len) : (i += 1) {
        dist_map.put(dres.order[i], dres.distances[i]) catch {};
    }
    const d_opt = dist_map.get(goal).?;
    try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(d_opt)), ares.final_distance, 0.0001);
}
