const std = @import("std");
const geode = @import("geode");
const builders = geode.graph.builders;
const pr = geode.graph.pagerank;

test "TestCANARY_REQ_GQL_067_PageRank" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Small deterministic directed graph forming a cycle plus a dangling node distribution influence.
    // 0->1, 1->2, 2->0 (cycle) and 2->3, 3 has no out edges (dangling).
    g.addNode(0);
    g.addNode(1);
    g.addNode(2);
    g.addNode(3);
    _ = g.addEdge(0, 1, 1) catch {};
    _ = g.addEdge(1, 2, 1) catch {};
    _ = g.addEdge(2, 0, 1) catch {};
    _ = g.addEdge(2, 3, 1) catch {};
    var res = try pr.compute(std.testing.allocator, &g, .{ .max_iterations = 80, .epsilon = 1e-10 });
    defer res.deinit(std.testing.allocator);
    // Expect 3 to have non-zero rank due to dangling distribution and incoming from 2.
    const idx3 = blk: {
        var i: usize = 0;
        while (i < res.node_ids.len) : (i += 1) if (res.node_ids[i] == 3) break :blk i;
        unreachable;
    };
    try std.testing.expect(res.ranks[idx3] > 0.05);
    // Convergence should be true
    try std.testing.expect(res.converged);
    // Sum of ranks ~1
    var sum: f64 = 0;
    for (res.ranks) |r| sum += r;
    try std.testing.expectApproxEqAbs(1.0, sum, 1e-6);
}
