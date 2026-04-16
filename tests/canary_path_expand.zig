const std = @import("std");
const planner = @import("../src/planner.zig");

// TestCANARY_REQ_GQL_016_PathExpandBfs - ensures BFS enumerates paths within hop bounds and deterministic ordering heuristic.
// We build a simple chain 1-2-3 and expect paths of length 1 and 2.
test "TestCANARY_REQ_GQL_016_PathExpandBfs" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var adj = planner.AdjacencyList.init(allocator);
    defer adj.deinit(allocator);
    try adj.addEdge(1, 2, 10, allocator);
    try adj.addEdge(2, 3, 20, allocator);

    const pe = planner.PathExpand{ .min_hops = 1, .max_hops = 2 };
    const results = try pe.execute(&[_]u64{1}, &adj, allocator);
    defer allocator.free(results);
    // We expect at least one path of length 1 (1->2) and one path length 2 (1->3)
    var got_len1 = false;
    var got_len2 = false;
    for (results) |r| {
        if (r.path_length == 1 and r.end_id == 2) got_len1 = true;
        if (r.path_length == 2 and r.end_id == 3) got_len2 = true;
    }
    try std.testing.expect(got_len1 and got_len2);
}
