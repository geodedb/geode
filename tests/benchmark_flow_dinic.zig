const std = @import("std");
const builders = @import("../src/graph/builders.zig");
const dinic = @import("../src/graph/flow_dinic.zig");

// BenchmarkCANARY_REQ_GQL_066_Dinic
test "BenchmarkCANARY_REQ_GQL_066_Dinic" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Build layered network: source -> layer1 -> layer2 -> sink with random-ish capacities
    const L1: u32 = 60;
    const L2: u32 = 60;
    const src: u32 = 1;
    const sink: u32 = 10000;
    for (0..L1) |i| {
        const v: u32 = 100 + @as(u32, @intCast(i));
        try g.addEdge(src, v, 5 + @as(f64, @floatFromInt(i % 7)));
    }
    for (0..L1) |i| for (0..L2) |j| {
        const a: u32 = 100 + @as(u32, @intCast(i));
        const b: u32 = 1000 + @as(u32, @intCast(j));
        const cap = 1 + @as(f64, @floatFromInt((i + j) % 11));
        if ((i + j) % 3 == 0) try g.addEdge(a, b, cap);
    };
    for (0..L2) |j| {
        const v: u32 = 1000 + @as(u32, @intCast(j));
        try g.addEdge(v, sink, 4 + @as(f64, @floatFromInt(j % 5)));
    }
    try g.rebuildIndex(std.testing.allocator);

    const iters: usize = 20;
    var timer = try std.time.Timer.start();
    var total: f64 = 0;
    for (0..iters) |_| {
        const f = try dinic.maxFlow(std.testing.allocator, &g, src, sink);
        total += f;
    }
    const elapsed = timer.read();
    const avg_ns = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iters));
    try std.testing.expect(avg_ns < 50_000_000); // performance guard
    try std.testing.expect(total > 0);
    std.debug.print("{s}\n", .{try std.json.stringifyAlloc(std.testing.allocator, .{ .avg_ns = avg_ns, .flow_total = total }, .{})});
}
