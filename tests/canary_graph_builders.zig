const std = @import("std");
const builders = @import("graph/builders.zig");

// TestCANARY_REQ_GQL_060_CoreGraphBuilders
test "TestCANARY_REQ_GQL_060_CoreGraphBuilders" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Build small graph 1->2 (w=1.0), 2->3 (w=2.0), 1->3 (w=0.5)
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(2, 3, 2.0);
    try g.addEdge(1, 3, 0.5);
    // Validate at least edges recorded for destinations 2 and 3
    var it2 = g.outEdges(2);
    const e2 = it2.next() orelse return error.MissingEdge;
    try std.testing.expect(e2.dst == 2);
    var it3 = g.outEdges(3);
    var count3: usize = 0;
    while (it3.next()) |_| count3 += 1;
    try std.testing.expect(count3 >= 2); // inbound from 1 and 2 (grouped by dst in this naive model)
}
