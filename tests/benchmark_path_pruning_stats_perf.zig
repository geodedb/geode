const std = @import("std");
const planner = @import("../src/planner.zig");

// BenchmarkCANARY_REQ_GQL_016_PathPruningStatsPerf
// Measures expansion pruning effectiveness by constructing a denser cyclic graph.

test "BenchmarkCANARY_REQ_GQL_016_PathPruningStatsPerf" {
    const allocator = std.testing.allocator;
    var adj = planner.AdjacencyList.init(allocator);
    defer adj.deinit(allocator);

    // Dense-ish cyclic graph
    var node: u64 = 1;
    // Build ring 1..30 and extra chords
    while (node < 30) : (node += 1) {
        try adj.addEdge(node, node + 1, 1000 + node, allocator);
        if (node + 2 <= 30) try adj.addEdge(node, node + 2, 2000 + node, allocator);
    }
    try adj.addEdge(30, 1, 1999, allocator);

    const expander = planner.PathExpand{ .min_hops = 1, .max_hops = 6 };

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
    try stdout.print("{\"benchmark\":\"BenchmarkCANARY_REQ_GQL_016_PathPruningStatsPerf\",\"elapsed_ns\":{d},\"paths\":{d},\"edges_in_paths\":{d}}\n", .{ elapsed, @as(usize, results.len), total_edges });
}
