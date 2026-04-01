// CANARY: REQ=REQ-GQL-063; FEATURE="Shortest Paths"; ASPECT=UnweightedBFSPaths; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_063_UnweightedBFSPaths; OWNER=graph; UPDATED=2025-09-20
// Unweighted shortest paths via BFS capturing predecessor tree and distance.
// Contract:
//  - Input: graph (with adjacency index built), start vertex id
//  - Output: struct { parents: []u64, distances: []u64, order: []u64 }
//    parents[v_idx] gives predecessor vertex id or UINT64_MAX for root/unreachable
//    distances[v_idx] is hop count or UINT64_MAX if unreachable
//  - Vertex ids are remapped into a dense index order defined by visitation order to keep arrays small.
// Limitations: only covers reachable subgraph from start. For full-domain distance array keyed by raw id,
// a future slice will add an id->index map export.
const std = @import("std");
const builders = @import("builders.zig");

pub const UnweightedBFSPaths = struct {
    pub const Result = struct {
        order: []u64, // visitation order (defines index mapping)
        parents: []u64, // same length as order; parent vertex id or UINT64_MAX
        distances: []u64, // same length; hop count from start
    };

    pub fn compute(alloc: std.mem.Allocator, g: *const builders.Graph, start: u64) !Result {
        if (!g.nodes.contains(start)) { // nodes hash map keyed by u64
            return Result{
                .order = try alloc.alloc(u64, 0),
                .parents = try alloc.alloc(u64, 0),
                .distances = try alloc.alloc(u64, 0),
            };
        }
        var visited = std.AutoHashMap(u64, usize).init(alloc); // vertex id -> index in arrays
        errdefer visited.deinit();

        var order_list = std.ArrayList(u64).init(alloc);
        errdefer order_list.deinit();
        var parents_list = std.ArrayList(u64).init(alloc);
        errdefer parents_list.deinit();
        var dist_list = std.ArrayList(u64).init(alloc);
        errdefer dist_list.deinit();

        try visited.put(start, 0);
        try order_list.append(@as(u64, start));
        try parents_list.append(std.math.maxInt(u64));
        try dist_list.append(0);

        var queue = std.ArrayList(u64).init(alloc);
        errdefer queue.deinit();
        try queue.append(start);

        while (queue.items.len > 0) {
            const v = queue.items[0];
            std.mem.copy(u64, queue.items[0 .. queue.items.len - 1], queue.items[1..]);
            _ = queue.pop();
            const v_idx = visited.get(v).?;
            var it = g.outEdges(v);
            while (it.next()) |e| {
                if (!visited.contains(e.dst)) {
                    const new_index = order_list.items.len;
                    try visited.put(e.dst, new_index);
                    try order_list.append(@as(u64, e.dst));
                    try parents_list.append(@as(u64, v));
                    try dist_list.append(dist_list.items[v_idx] + 1);
                    try queue.append(e.dst);
                }
            }
        }

        return Result{
            .order = try order_list.toOwnedSlice(),
            .parents = try parents_list.toOwnedSlice(),
            .distances = try dist_list.toOwnedSlice(),
        };
    }
};

test "TestCANARY_REQ_GQL_063_UnweightedBFSPaths simple" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    g.addNode(1);
    g.addNode(2);
    g.addNode(3);
    g.addNode(4);
    try g.addEdge(1, 2, 1);
    try g.addEdge(2, 3, 1);
    try g.addEdge(1, 4, 1);
    // rebuildIndex implicit in addEdge currently
    const res = try UnweightedBFSPaths.compute(std.testing.allocator, &g, 1);
    defer std.testing.allocator.free(res.order);
    defer std.testing.allocator.free(res.parents);
    defer std.testing.allocator.free(res.distances);
    // Expect visitation order: 1,2,4,3 (depending on edge ordering; builder preserves insertion order of edges per src)
    try std.testing.expect(res.order.len == res.parents.len);
    try std.testing.expect(res.order.len == res.distances.len);
    // root
    try std.testing.expect(res.parents[0] == std.math.maxInt(u64));
    try std.testing.expect(res.distances[0] == 0);
    // Distances must be non-decreasing with index except sibling ordering variance; check known distances by id
    // Reconstruct map id->(parent,distance)
    var map = std.AutoHashMap(u64, struct { p: u64, d: u64 }).init(std.testing.allocator);
    defer map.deinit();
    var i: usize = 0;
    while (i < res.order.len) : (i += 1) {
        try map.put(res.order[i], .{ .p = res.parents[i], .d = res.distances[i] });
    }
    const root = map.get(1).?;
    try std.testing.expect(root.d == 0);
    const two = map.get(2).?;
    try std.testing.expect(two.d == 1 and two.p == 1);
    const four = map.get(4).?;
    try std.testing.expect(four.d == 1 and four.p == 1);
    const three = map.get(3).?;
    try std.testing.expect(three.d == 2 and three.p == 2);
}
