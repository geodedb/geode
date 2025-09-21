const std = @import("std");
const geode = @import("geode");
const builders = geode.graph.builders;
const close = geode.graph.closeness;

test "TestCANARY_REQ_GQL_067_Closeness" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Star 0 center to 1..5 (bidirectional). Center closeness should dominate.
    g.addNode(0);
    var i: u32 = 1;
    while (i <= 5) : (i += 1) {
        g.addNode(i);
        _ = g.addEdge(0, i, 1) catch {};
        _ = g.addEdge(i, 0, 1) catch {};
    }
    var res = try close.compute(std.testing.allocator, &g, .{ .mode = .standard, .normalize = true });
    defer res.deinit(std.testing.allocator);
    var center_idx: usize = 0;
    while (center_idx < res.node_ids.len) : (center_idx += 1) if (res.node_ids[center_idx] == 0) break;
    const center = res.scores[center_idx];
    var j: usize = 0;
    while (j < res.scores.len) : (j += 1) if (j != center_idx) try std.testing.expect(center > res.scores[j]);
}
