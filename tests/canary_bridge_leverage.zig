const std = @import("std");
const geode = @import("geode");
const builders = geode.graph.builders;
const bridge = @import("../src/graph/centrality_bridge_leverage.zig");

test "TestCANARY_REQ_GQL_067_BridgeLeverage" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Build two cliques of size 4 connected by single node 0 bridging both (0 plus 1..3) and (0 plus 4..6)
    var i: u32 = 0;
    while (i < 7) : (i += 1) g.addNode(i);
    // Clique 1 (0,1,2,3)
    var a: u32 = 0;
    while (a < 4) : (a += 1) {
        var b: u32 = a + 1;
        while (b < 4) : (b += 1) {
            _ = g.addEdge(a, b, 1) catch {};
            _ = g.addEdge(b, a, 1) catch {};
        }
    }
    // Clique 2 (0,4,5,6)
    var c: u32 = 4;
    while (c < 7) : (c += 1) {
        _ = g.addEdge(0, c, 1) catch {};
        _ = g.addEdge(c, 0, 1) catch {};
    }
    var d: u32 = 4;
    while (d < 7) : (d += 1) {
        var e: u32 = d + 1;
        while (e < 7) : (e += 1) {
            _ = g.addEdge(d, e, 1) catch {};
            _ = g.addEdge(e, d, 1) catch {};
        }
    }
    var res = try bridge.compute(std.testing.allocator, &g, .{ .normalize = true });
    defer res.deinit(std.testing.allocator);
    var idx0: usize = 0;
    while (idx0 < res.node_ids.len) : (idx0 += 1) if (res.node_ids[idx0] == 0) break;
    const score0 = res.scores[idx0];
    var j: usize = 0;
    while (j < res.scores.len) : (j += 1) if (j != idx0) try std.testing.expect(score0 >= res.scores[j]);
}
