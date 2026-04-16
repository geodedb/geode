const std = @import("std");
const builders = @import("../src/graph/builders.zig");
const tarjan = @import("../src/graph/connectivity_tarjan_scc.zig");

// TestCANARY_REQ_GQL_064_TarjanSCC
// Graph structure:
// 0 -> 1 -> 2 -> 0 (SCC1)
// 2 -> 3 -> 4 -> 5 -> 3 (SCC2)
// 6 isolated (SCC3 single)
// 5 -> 7 (edge to singleton) => 7 alone (SCC4)
// Expect 4 SCCs: {0,1,2} {3,4,5} {6} {7}

test "TestCANARY_REQ_GQL_064_TarjanSCC" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var g = builders.Graph.init(alloc);
    defer g.deinit();

    for (0..8) |i| try g.addNode(@as(u32, @intCast(i)));

    try g.addEdge(0, 1, 1);
    try g.addEdge(1, 2, 1);
    try g.addEdge(2, 0, 1);

    try g.addEdge(2, 3, 1);
    try g.addEdge(3, 4, 1);
    try g.addEdge(4, 5, 1);
    try g.addEdge(5, 3, 1);

    try g.addEdge(5, 7, 1);

    var res = try tarjan.compute(alloc, g);
    defer res.deinit(alloc);

    // Gather components into hash sets for flexible order checking
    var seen = std.AutoHashMap(u32, u32).init(alloc);
    defer seen.deinit();

    var counts: usize = 0;
    var found_scc1 = false;
    var found_scc2 = false;
    var found_scc3 = false;
    var found_scc4 = false;

    for (res.components) |comp| {
        counts += 1;
        // Build bitmask signature
        var mask: u32 = 0;
        for (comp) |v| mask |= @as(u32, 1) << v;
        switch (mask) {
            // {0,1,2}
            (1 << 0) | (1 << 1) | (1 << 2) => found_scc1 = true,
            // {3,4,5}
            (1 << 3) | (1 << 4) | (1 << 5) => found_scc2 = true,
            // {6}
            (1 << 6) => found_scc3 = true,
            // {7}
            (1 << 7) => found_scc4 = true,
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 4), counts);
    try std.testing.expect(found_scc1);
    try std.testing.expect(found_scc2);
    try std.testing.expect(found_scc3);
    try std.testing.expect(found_scc4);
}
