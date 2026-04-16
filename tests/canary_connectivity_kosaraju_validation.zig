const std = @import("std");
const builders = @import("../src/graph/builders.zig");
const tarjan = @import("../src/graph/connectivity_tarjan_scc.zig");
const kosaraju = @import("../src/graph/connectivity_kosaraju.zig");

// TestCANARY_REQ_GQL_064_Kosaraju
// Validates Kosaraju output matches Tarjan on random-ish structured graph.

fn signature(alloc: std.mem.Allocator, comps: [][]u32) ![][]u32 {
    // Each component slice already sorted internally; we need to sort list of components lexicographically.
    const list = try alloc.alloc([]u32, comps.len);
    @memcpy(list, comps);
    std.sort.sort([]u32, list, {}, struct {
        pub fn lessThan(_: @This(), a: []u32, b: []u32) bool {
            var i: usize = 0;
            while (i < a.len and i < b.len) : (i += 1) {
                if (a[i] < b[i]) return true;
                if (a[i] > b[i]) return false;
            }
            return a.len < b.len;
        }
    }{});
    return list;
}

test "TestCANARY_REQ_GQL_064_Kosaraju" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var g = builders.Graph.init(alloc);
    defer g.deinit();

    // Construct graph with multiple SCC shapes
    // SCC A: 0->1->2->0
    // SCC B: 3->4->5->3 plus a tail 5->6
    // SCC C: 7 isolated, SCC D: 8->9->8, cross edges 2->3, 5->8, 9->2 (forming a meta cycle among A,B,D but separate SCCs internally) is avoided intentionally

    for (0..10) |i| try g.addNode(@as(u32, @intCast(i)));
    // A
    try g.addEdge(0, 1, 1);
    try g.addEdge(1, 2, 1);
    try g.addEdge(2, 0, 1);
    // B
    try g.addEdge(3, 4, 1);
    try g.addEdge(4, 5, 1);
    try g.addEdge(5, 3, 1);
    try g.addEdge(5, 6, 1);
    // D
    try g.addEdge(8, 9, 1);
    try g.addEdge(9, 8, 1);
    // Cross without merging SCCs (only one direction edges to avoid condensation cycles)
    try g.addEdge(2, 3, 1); // A -> B
    try g.addEdge(6, 7, 1); // single chain to isolated
    try g.addEdge(5, 8, 1); // B -> D

    var t_res = try tarjan.compute(alloc, g);
    defer t_res.deinit(alloc);
    var k_res = try kosaraju.compute(alloc, g);
    defer k_res.deinit(alloc);

    // Normalize components (each component members already sorted) and compare multiset equality via lexicographic ordering of component list.

    const sig_t = try signature(alloc, t_res.components);
    defer alloc.free(sig_t);
    const sig_k = try signature(alloc, k_res.components);
    defer alloc.free(sig_k);

    try std.testing.expectEqual(sig_t.len, sig_k.len);
    for (sig_t, 0..) |comp, i| {
        const other = sig_k[i];
        try std.testing.expectEqual(comp.len, other.len);
        for (comp, 0..) |v, j| try std.testing.expectEqual(v, other[j]);
    }
}
