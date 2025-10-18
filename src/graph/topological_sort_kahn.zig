// CANARY: REQ=REQ-GQL-062; FEATURE="Traversals"; ASPECT=TopologicalSortKahn; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_062_TopoKahn; BENCH=BenchmarkCANARY_REQ_GQL_062_TopoKahn; OWNER=graph; UPDATED=2025-09-21
// Deterministic Kahn topological sort. If cycle detected returns error.CycleDetected.
const std = @import("std");
const builders = @import("builders.zig");

pub const Error = error{CycleDetected} || std.mem.Allocator.Error;

pub fn sort(allocator: std.mem.Allocator, g: *const builders.Graph) Error![]u32 {
    // Compute indegree
    var indeg = std.AutoHashMap(u32, u32).init(allocator);
    errdefer indeg.deinit();
    var it_nodes = g.nodes.iterator();
    while (it_nodes.next()) |entry| try indeg.put(entry.key_ptr.*, 0);
    for (g.edges.items) |e| {
        const cur = indeg.get(e.dst) orelse 0;
        try indeg.put(e.dst, cur + 1);
    }
    // Min-heap (actually simple array + sort each iteration acceptable small scale) of zero indegree nodes for deterministic ordering
    var zeros = std.ArrayList(u32).init(allocator);
    errdefer zeros.deinit();
    var it_nodes2 = g.nodes.iterator();
    while (it_nodes2.next()) |entry| if ((indeg.get(entry.key_ptr.*) orelse 0) == 0) try zeros.append(entry.key_ptr.*);
    std.sort.heap(u32, zeros.items, {}, comptime std.sort.asc(u32));
    var out = std.ArrayList(u32).init(allocator);
    errdefer out.deinit();
    while (zeros.items.len > 0) {
        const v = zeros.pop(); // pop largest; maintain min behavior by reverse append then sort, simpler: we popped largest, so resort
        try out.append(v);
        // For stable ascending, resort after collecting new zeros later; for now gather children
        var out_it = g.outEdges(v);
        while (out_it.next()) |edge| {
            const curd = indeg.get(edge.dst) orelse 0;
            if (curd <= 1) {
                try indeg.put(edge.dst, 0);
                try zeros.append(edge.dst);
            } else try indeg.put(edge.dst, curd - 1);
        }
        std.sort.heap(u32, zeros.items, {}, comptime std.sort.asc(u32));
    }
    if (out.items.len != g.nodes.count()) return error.CycleDetected;
    return out.toOwnedSlice();
}

test "TestCANARY_REQ_GQL_062_TopoKahn basic DAG" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    try g.addEdge(1, 2, 1);
    try g.addEdge(2, 3, 1);
    try g.addEdge(1, 3, 1);
    try g.rebuildIndex(std.testing.allocator);
    const order = try sort(std.testing.allocator, &g);
    defer std.testing.allocator.free(order);
    try std.testing.expect(order.len == 3);
    // Order must respect 1 before 2 before 3
    var pos = std.AutoHashMap(u32, usize).init(std.testing.allocator);
    defer pos.deinit();
    for (order, 0..) |v, i| try pos.put(v, i);
    try std.testing.expect((pos.get(1) orelse 9) < (pos.get(2) orelse 9));
    try std.testing.expect((pos.get(2) orelse 9) < (pos.get(3) orelse 9));
}

test "TestCANARY_REQ_GQL_062_TopoKahn cycle" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    try g.addEdge(1, 2, 1);
    try g.addEdge(2, 1, 1);
    try g.rebuildIndex(std.testing.allocator);
    const res = sort(std.testing.allocator, &g);
    try std.testing.expectError(error.CycleDetected, res);
}
