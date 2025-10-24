// CANARY: REQ=REQ-GQL-062; FEATURE="Traversals"; ASPECT=BFS; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_062_BFS; OWNER=graph; UPDATED=2025-09-20
// Breadth First Search traversal over the directed weighted graph structure.
// The builder graph in builders.zig stores an adjacency index we can leverage.
// Contract:
//  - Input: graph (with rebuildIndex already called), start vertex id
//  - Output: visitation order slice (allocator owned by caller) containing each reachable vertex exactly once.
//  - Determinism: Uses queue (FIFO) ensuring layer order and stable iteration over stored out-edges order.
//  - If start vertex missing, returns empty slice (not error) to simplify caller code.
// Edge cases handled: start not present, isolated vertex, graph with cycles.
const std = @import("std");
const builders = @import("builders.zig");

pub const BFS = struct {
    pub fn traverse(alloc: std.mem.Allocator, g: *const builders.Graph, start: u64) ![]u64 {
        if (!g.nodes.contains(start)) {
            return try alloc.alloc(u64, 0);
        }
        var visited = std.AutoHashMap(u64, void).init(alloc);
        errdefer visited.deinit();
        try visited.put(start, {});

        var order = std.ArrayList(u64).init(alloc);
        errdefer order.deinit();
        try order.append(start);

        var queue = std.ArrayList(u64).init(alloc);
        errdefer queue.deinit();
        try queue.append(start);

        while (queue.items.len > 0) {
            const v = queue.items[0];
            // pop front (small queues expected for tests; simple shift acceptable)
            std.mem.copy(u64, queue.items[0 .. queue.items.len - 1], queue.items[1..]);
            _ = queue.pop();

            const edges = g.outEdges(v) orelse continue;
            for (edges) |e| {
                if (!visited.contains(e.dst)) {
                    try visited.put(e.dst, {});
                    try order.append(e.dst);
                    try queue.append(e.dst);
                }
            }
        }
        // transfer ownership
        return order.toOwnedSlice();
    }
};

test "TestCANARY_REQ_GQL_062_BFS basic traversal" {
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

    const order = try BFS.traverse(std.testing.allocator, &g, 1);
    defer std.testing.allocator.free(order);
    // Expected BFS layer order: 1,2,3,4 (since 2 discovered before 3's children)
    try std.testing.expect(order.len == 4);
    try std.testing.expect(order[0] == 1);
    try std.testing.expect(order[1] == 2);
    try std.testing.expect(order[2] == 3);
    try std.testing.expect(order[3] == 4);
}

test "TestCANARY_REQ_GQL_062_BFS start missing" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    try g.addNode(5);
    try g.rebuildIndex(std.testing.allocator);
    const order = try BFS.traverse(std.testing.allocator, &g, 42);
    defer std.testing.allocator.free(order);
    try std.testing.expect(order.len == 0);
}

test "TestCANARY_REQ_GQL_062_BFS cycle" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    try g.addNode(1);
    try g.addNode(2);
    try g.addEdge(1, 2, 1);
    try g.addEdge(2, 1, 1); // cycle
    try g.rebuildIndex(std.testing.allocator);
    const order = try BFS.traverse(std.testing.allocator, &g, 1);
    defer std.testing.allocator.free(order);
    try std.testing.expect(order.len == 2);
}
