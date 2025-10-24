const std = @import("std");
const graph = @import("../src/graph/connectivity_biconnected.zig");
const builders = @import("../src/graph/builders.zig");

// TestCANARY_REQ_GQL_064_Biconnected
// Verifies articulation points and biconnected components on a known graph.
// Graph shape (classic articulation example):
//   1 -- 2 -- 3 -- 4
//         |    \
//         5     5
// Components: {1,2}, {2,3,5}, {3,4,5}
// Articulation: 2,3

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var g = try builders.Graph.init(alloc);
    defer g.deinit();

    // Add nodes 1..5
    for (1..6) |id| {
        _ = try g.addNode(@as(u32, @intCast(id)));
    }

    // Edges (undirected modeled as bidirectional for algorithm input)
    const edges = [_][2]u32{ .{ 1, 2 }, .{ 2, 3 }, .{ 3, 4 }, .{ 2, 5 }, .{ 3, 5 }, .{ 4, 5 } };
    for (edges) |e| {
        _ = try g.addEdge(e[0], e[1]);
        _ = try g.addEdge(e[1], e[0]);
    }

    const res = try graph.compute(alloc, g);
    defer res.deinit(alloc);

    // Collect articulation into a set
    try std.testing.expect(res.articulation.len == 2);
    try std.testing.expect(res.articulation[0] == 2);
    try std.testing.expect(res.articulation[1] == 3);

    // We expect 3 components (order not guaranteed). We'll validate by multiset sizes.
    try std.testing.expect(res.components.len == 3);
    var size_counts = std.AutoHashMap(usize, usize).init(alloc);
    defer size_counts.deinit();
    for (res.components) |c| {
        const len = c.len;
        const entry = try size_counts.getOrPut(len);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }
    // Expect counts: size2 ->1, size3 ->2
    try std.testing.expect(size_counts.get(2).? == 1);
    try std.testing.expect(size_counts.get(3).? == 2);
}
