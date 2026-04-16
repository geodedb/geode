const std = @import("std");
const builders = @import("../src/graph/builders.zig");
const dijkstra = @import("../src/graph/shortest_dijkstra.zig");

// TestCANARY_REQ_GQL_063_Dijkstra
// Verifies correctness on a small weighted graph with multiple equal-cost paths enforcing deterministic parent tie-break.

test "TestCANARY_REQ_GQL_063_Dijkstra" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var g = builders.Graph.init(alloc);
    defer g.deinit();

    // Graph layout:
    // 0 ->1 (1), 0 ->2 (1)
    // 1 ->3 (2), 2 ->3 (2)   // two equal paths 0-1-3 and 0-2-3 distance 3
    // 0 ->3 (5) (longer direct)
    try g.addNode(0);
    try g.addNode(1);
    try g.addNode(2);
    try g.addNode(3);
    try g.addEdge(0, 1, 1);
    try g.addEdge(0, 2, 1);
    try g.addEdge(1, 3, 2);
    try g.addEdge(2, 3, 2);
    try g.addEdge(0, 3, 5);

    var res = try dijkstra.compute(alloc, g, 0, null);
    defer res.deinit(alloc);

    // Confirm distance to 3 is 3
    var idx_3: ?usize = null;
    // search order array for node ids to build dense mapping
    var map = std.AutoHashMap(u32, usize).init(alloc);
    defer map.deinit();
    for (res.order, 0..) |id, i| try map.put(id, i);
    // Build distance lookup by scanning distances vs order mapping
    for (res.order, 0..) |id, i| {
        if (id == 3) idx_3 = i;
    }
    try std.testing.expect(idx_3 != null);

    // Build distances map
    var dist_map = std.AutoHashMap(u32, u64).init(alloc);
    defer dist_map.deinit();
    for (res.order, 0..) |id, i| try dist_map.put(id, res.distances[i]);

    const d3 = dist_map.get(3).?;
    try std.testing.expectEqual(@as(u64, 3), d3);

    // Tie-break: parent of 3 should be the smaller id among {1,2} which is 1
    // Find parent for 3 by correlating order index to parents entry.
    const parent_id = res.parents[idx_3.?];
    try std.testing.expectEqual(@as(i32, 1), parent_id);
}
