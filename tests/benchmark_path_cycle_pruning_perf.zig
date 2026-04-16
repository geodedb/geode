const std = @import("std");
const planner = @import("../src/planner.zig");

// BenchmarkCANARY_REQ_GQL_016_PathCyclePruningPerf
// Constructs a graph with cycles and measures BFS expansion overhead with simple path constraint.

test "BenchmarkCANARY_REQ_GQL_016_PathCyclePruningPerf" {
    const allocator = std.testing.allocator;
    var adj = planner.AdjacencyList.init(allocator);
    defer adj.deinit(allocator);

    // Create a cyclic graph: 1->2->3->1 and tail 3->4->5
    try adj.addEdge(1, 2, 101, allocator);
    try adj.addEdge(2, 3, 102, allocator);
    try adj.addEdge(3, 1, 103, allocator);
    try adj.addEdge(3, 4, 104, allocator);
    try adj.addEdge(4, 5, 105, allocator);

    const expander = planner.PathExpand{ .min_hops = 1, .max_hops = 4 };

    const start = std.time.nanoTimestamp();
    const start_nodes = [_]u64{1};
    const results = try expander.execute(start_nodes[0..], &adj, allocator);
    const end = std.time.nanoTimestamp();

    var total_edges: usize = 0;
    for (results) |r| total_edges += r.edge_ids.len;

    for (results) |r| allocator.free(r.edge_ids);
    allocator.free(results);

    const elapsed = end - start;
    const stdout = std.Io.getStdOut().writer();
    try stdout.print("{\"benchmark\":\"BenchmarkCANARY_REQ_GQL_016_PathCyclePruningPerf\",\"elapsed_ns\":{d},\"paths\":{d},\"edges_in_paths\":{d}}\n", .{ elapsed, @as(usize, results.len), total_edges });
}
