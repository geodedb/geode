const std = @import("std");
const planner = @import("../src/planner.zig");

// BenchmarkCANARY_REQ_GQL_016_PathExpandMemPerf
// Approximates memory usage of path expansion by counting allocations implied by edge_ids lengths.

test "BenchmarkCANARY_REQ_GQL_016_PathExpandMemPerf" {
    const allocator = std.testing.allocator;
    var adj = planner.AdjacencyList.init(allocator);
    defer adj.deinit(allocator);

    // Build branching tree: each node k has edges to k*2 and k*2+1 up to depth
    var i: u64 = 1;
    while (i < 128) : (i += 1) {
        const left = i * 2;
        const right = i * 2 + 1;
        if (left < 256) try adj.addEdge(i, left, 10_000 + left, allocator);
        if (right < 256) try adj.addEdge(i, right, 10_000 + right, allocator);
    }

    const expander = planner.PathExpand{ .min_hops = 1, .max_hops = 6 };
    const start = std.time.nanoTimestamp();
    const roots = [_]u64{1};
    const results = try expander.execute(roots[0..], &adj, allocator);
    const end = std.time.nanoTimestamp();
    var total_edges: usize = 0;
    for (results) |r| total_edges += r.edge_ids.len;
    for (results) |r| allocator.free(r.edge_ids);
    allocator.free(results);
    const elapsed = end - start;
    const stdout = std.Io.getStdOut().writer();
    try stdout.print("{\"benchmark\":\"BenchmarkCANARY_REQ_GQL_016_PathExpandMemPerf\",\"elapsed_ns\":{d},\"accum_edge_ids\":{d}}\n", .{ elapsed, total_edges });
}
