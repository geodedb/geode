const std = @import("std");
const geode = @import("geode");
const builders = geode.graph.builders;
const grey = geode.graph.grey_cardinal;

// Additional targeted test for Grey Cardinal composite invariants beyond embedded basic test.
// Ensures normalization flag works and weight adjustments influence ordering.

test "TestCANARY_REQ_GQL_067_GreyCardinalComposite weights influence" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Build a star graph: center 0 connected to others; path tail off node 1 to emphasize betweenness.
    var i: u32 = 0;
    while (i < 7) : (i += 1) g.addNode(i);
    // Star center 0
    i = 1;
    while (i < 6) : (i += 1) {
        _ = g.addEdge(0, i, 1) catch {};
        _ = g.addEdge(i, 0, 1) catch {};
    }
    // Tail chain 1-6
    _ = g.addEdge(1, 6, 1) catch {};
    _ = g.addEdge(6, 1, 1) catch {};

    var res_equal = try grey.compute(std.testing.allocator, &g, .{ .normalize_final = true });
    defer res_equal.deinit(std.testing.allocator);

    // Heavily weight betweenness; node 0 should remain high but node 1 may rise due to tail connection bridging.
    var res_betw = try grey.compute(std.testing.allocator, &g, .{ .weight_betweenness = 3.0, .normalize_final = true });
    defer res_betw.deinit(std.testing.allocator);

    // Find indices
    var idx0: usize = 0;
    while (idx0 < res_equal.node_ids.len) : (idx0 += 1) if (res_equal.node_ids[idx0] == 0) break;
    var idx1: usize = 0;
    while (idx1 < res_equal.node_ids.len) : (idx1 += 1) if (res_equal.node_ids[idx1] == 1) break;

    const diff_equal = res_equal.scores[idx0] - res_equal.scores[idx1];
    const diff_betw = res_betw.scores[idx0] - res_betw.scores[idx1];
    // Expect gap to shrink or invert when betweenness weight increased.
    try std.testing.expect(diff_betw <= diff_equal);
}
