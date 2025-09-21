// CANARY: REQ=REQ-GQL-062; FEATURE="Traversals"; ASPECT=DFSIterative; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_062_DFSIterative; BENCH=BenchmarkCANARY_REQ_GQL_062_DFSIterative; OWNER=graph; UPDATED=2025-09-21
// Iterative Depth First Search traversal over the directed weighted graph structure.
// Contract:
//  - Input: graph (with rebuilt adjacency index), start vertex id
//  - Output: visitation order (pre-order) containing each reachable vertex exactly once.
//  - Determinism: We push children onto a stack in reverse adjacency order so that popping
//    yields natural left-to-right order consistent with stored adjacency slice ordering.
//  - Missing start vertex: returns empty slice (not an error) mirroring BFS contract.
//  - Cycles: handled via visited set.
const std = @import("std");
const builders = @import("builders.zig");

pub const DFSIterative = struct {
    pub fn traverse(alloc: std.mem.Allocator, g: *const builders.Graph, start: u64) ![]u64 {
        if (!g.nodes.contains(@as(u32, @intCast(start)))) {
            return try alloc.alloc(u64, 0);
        }
        var visited = std.AutoHashMap(u64, void).init(alloc);
        errdefer visited.deinit();
        try visited.put(start, {});

        var order = std.ArrayList(u64).init(alloc);
        errdefer order.deinit();
        try order.append(start);

        var stack = std.ArrayList(u64).init(alloc);
        errdefer stack.deinit();
        try stack.append(start);

        while (stack.items.len > 0) {
            const v = stack.pop();
            // Iterate adjacency slice to collect unseen children; to preserve stable ordering
            // we push them in reverse so earliest neighbor is processed first when popped.
            var edges_iter = g.outEdges(@as(u32, @intCast(v)));
            // Collect neighbors into a temporary array to reverse-push.
            var neigh = std.ArrayList(u64).init(alloc);
            defer neigh.deinit();
            while (edges_iter.next()) |e| {
                if (!visited.contains(e.dst)) {
                    try visited.put(e.dst, {});
                    try neigh.append(e.dst);
                }
            }
            const slice = neigh.items;
            var i: isize = @as(isize, @intCast(slice.len)) - 1;
            while (i >= 0) : (i -= 1) {
                const child = slice[@as(usize, @intCast(i))];
                try order.append(child);
                try stack.append(child);
            }
        }
        return order.toOwnedSlice();
    }
};

test "TestCANARY_REQ_GQL_062_DFSIterative basic pre-order traversal" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    try g.addNode(1);
    try g.addNode(2);
    try g.addNode(3);
    try g.addNode(4);
    try g.addEdge(1, 2, 1);
    try g.addEdge(1, 3, 1);
    try g.addEdge(2, 4, 1);
    try g.rebuildIndex(std.testing.allocator);
    const order = try DFSIterative.traverse(std.testing.allocator, &g, 1);
    defer std.testing.allocator.free(order);
    // Expected pre-order: 1,2,4,3 (since 2's subtree explored fully before 3)
    try std.testing.expect(order.len == 4);
    try std.testing.expect(order[0] == 1);
    try std.testing.expect(order[1] == 2);
    try std.testing.expect(order[2] == 4);
    try std.testing.expect(order[3] == 3);
}

test "TestCANARY_REQ_GQL_062_DFSIterative cycle & missing start" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    try g.addNode(10);
    try g.addNode(11);
    try g.addEdge(10, 11, 1);
    try g.addEdge(11, 10, 1); // cycle
    try g.rebuildIndex(std.testing.allocator);
    const order_cycle = try DFSIterative.traverse(std.testing.allocator, &g, 10);
    defer std.testing.allocator.free(order_cycle);
    try std.testing.expect(order_cycle.len == 2);
    const empty = try DFSIterative.traverse(std.testing.allocator, &g, 9999);
    defer std.testing.allocator.free(empty);
    try std.testing.expect(empty.len == 0);
}
