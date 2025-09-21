const std = @import("std");
const geode = @import("geode");
const builders = geode.graph.builders;
const betw = geode.graph.betweenness;

test "TestCANARY_REQ_GQL_067_Betweenness" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Path graph 0-1-2-3-4; interior nodes 1,2,3 should have higher betweenness than endpoints.
    var i: u32 = 0;
    while (i <= 4) : (i += 1) g.addNode(i);
    i = 0;
    while (i < 4) : (i += 1) {
        _ = g.addEdge(i, i + 1, 1) catch {};
        _ = g.addEdge(i + 1, i, 1) catch {};
    }
    var res = try betw.compute(std.testing.allocator, &g, .{ .normalize = false });
    defer res.deinit(std.testing.allocator);
    // Map id->score
    var idx0: usize = 0;
    while (idx0 < res.node_ids.len) : (idx0 += 1) if (res.node_ids[idx0] == 0) break;
    var idx1: usize = 0;
    while (idx1 < res.node_ids.len) : (idx1 += 1) if (res.node_ids[idx1] == 1) break;
    var idx2: usize = 0;
    while (idx2 < res.node_ids.len) : (idx2 += 1) if (res.node_ids[idx2] == 2) break;
    var idx4: usize = 0;
    while (idx4 < res.node_ids.len) : (idx4 += 1) if (res.node_ids[idx4] == 4) break;
    try std.testing.expect(res.scores[idx1] > res.scores[idx0]);
    try std.testing.expect(res.scores[idx2] > res.scores[idx0]);
    try std.testing.expect(res.scores[idx1] == res.scores[idx2]);
    try std.testing.expect(res.scores[idx0] == res.scores[idx4]);
}
