const std = @import("std");
const geode = @import("geode");
const builders = geode.graph.builders;
const eigen = geode.graph.eigenvector;

test "TestCANARY_REQ_GQL_067_Eigenvector" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Two joined star centers to test relative influence.
    // 0 connected to 1..4, 5 connected to 6..8, plus bridge 0<->5 (bidirectional)
    var i: u32 = 0;
    while (i <= 8) : (i += 1) g.addNode(i);
    // Star A
    i = 1;
    while (i <= 4) : (i += 1) {
        _ = g.addEdge(0, i, 1) catch {};
        _ = g.addEdge(i, 0, 1) catch {};
    }
    // Star B smaller (5 with leaves 6..8)
    i = 6;
    while (i <= 8) : (i += 1) {
        _ = g.addEdge(5, i, 1) catch {};
        _ = g.addEdge(i, 5, 1) catch {};
    }
    // Bridge
    _ = g.addEdge(0, 5, 1) catch {};
    _ = g.addEdge(5, 0, 1) catch {};
    var res = try eigen.compute(std.testing.allocator, &g, .{ .max_iterations = 120, .epsilon = 1e-11 });
    defer res.deinit(std.testing.allocator);
    // Expect center 0 score > center 5 due to higher degree
    var idx0: usize = 0;
    while (idx0 < res.node_ids.len) : (idx0 += 1) if (res.node_ids[idx0] == 0) break;
    var idx5: usize = 0;
    while (idx5 < res.node_ids.len) : (idx5 += 1) if (res.node_ids[idx5] == 5) break;
    try std.testing.expect(res.scores[idx0] > res.scores[idx5]);
    try std.testing.expect(res.converged);
}
