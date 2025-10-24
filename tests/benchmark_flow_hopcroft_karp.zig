const std = @import("std");
const builders = @import("../src/graph/builders.zig");
const hk = @import("../src/graph/flow_hopcroft_karp.zig");

// BenchmarkCANARY_REQ_GQL_066_HopcroftKarp
test "BenchmarkCANARY_REQ_GQL_066_HopcroftKarp" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    const L: u32 = 300;
    const R: u32 = 300;
    const left_start: u32 = 10;
    const right_start: u32 = 10_000;
    // Build near-complete bipartite with stride to keep density moderate
    for (0..L) |i| {
        const u: u32 = left_start + @as(u32, @intCast(i));
        for (0..R) |j| {
            if ((i + j) % 5 == 0) {
                const v: u32 = right_start + @as(u32, @intCast(j));
                try g.addEdge(u, v, 1);
            }
        }
    }
    try g.rebuildIndex(std.testing.allocator);
    var left = std.ArrayList(u32).init(std.testing.allocator);
    defer left.deinit();
    for (0..L) |i| left.append(left_start + @as(u32, @intCast(i))) catch unreachable;
    const iters: usize = 10;
    var total: usize = 0;
    var timer = try std.time.Timer.start();
    for (0..iters) |_| {
        var res = try hk.maximumMatching(std.testing.allocator, &g, left.items);
        total += res.size;
        res.pairs.deinit();
    }
    const elapsed = timer.read();
    const avg_ns = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iters));
    try std.testing.expect(avg_ns < 90_000_000); // guard
    try std.testing.expect(total > 0);
    std.debug.print("{s}\n", .{try std.json.stringifyAlloc(std.testing.allocator, .{ .avg_ns = avg_ns, .total = total }, .{})});
}
