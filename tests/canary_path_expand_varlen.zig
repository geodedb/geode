const std = @import("std");
const planner = @import("../src/planner.zig");

// TestCANARY_REQ_GQL_016_PathExpandVarLen - ensures variable length path expansion (1..3 hops) produces bounded results.

test "TestCANARY_REQ_GQL_016_PathExpandVarLen" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    // Build adjacency list forming a linear chain 0-1-2-3 plus a back edge 1-0
    var adj = try planner.AdjacencyList.init(ally, 4);
    defer adj.deinit();
    try adj.addEdge(0, 1);
    try adj.addEdge(1, 2);
    try adj.addEdge(2, 3);
    try adj.addEdge(1, 0);

    // Collect paths up to length 3 starting at 0
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    const a = arena.allocator();

    var results = std.ArrayList([]u32).init(a);

    try planner.variableLengthExpand(&adj, 0, 1, 3, &results);

    // Validate all path lengths within 1..3 and no path repeats immediate edge loops beyond bounds
    for (results.items) |path| {
        try std.testing.expect(path.len >= 2 and path.len <= 4); // nodes = edges+1
        // simple sanity: start node is 0
        try std.testing.expect(path[0] == 0);
    }
    try std.testing.expect(results.items.len > 0);
}
