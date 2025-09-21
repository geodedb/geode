const std = @import("std");
const cd = @import("../src/graph/cycle_detect_directed.zig");

// BenchmarkCANARY_REQ_GQL_062_CycleDirected
test "BenchmarkCANARY_REQ_GQL_062_CycleDirected" {
    var g = cd.SimpleAdj.init(std.testing.allocator);
    defer g.deinit();
    // build synthetic graph with occasional cycles
    const N: u64 = 800;
    for (0..N) |i| {
        const u = @as(u64, i);
        const v = (u + 1) % N;
        try g.addEdge(u, v);
        if (u % 50 == 0 and u + 3 < N) try g.addEdge(u + 3, u); // introduce back-edge forming a cycle
    }
    var verts = std.ArrayList(u64).init(std.testing.allocator);
    defer verts.deinit();
    for (0..N) |i| verts.append(@as(u64, i)) catch unreachable;

    const iters: usize = 60;
    var timer = try std.time.Timer.start();
    var detected: usize = 0;
    for (0..iters) |_| {
        const res = try cd.DirectedCycle.detect(std.testing.allocator, verts.items, @ptrCast(&g), cd.SimpleAdj.neighCtx);
        if (res.cycle) |c| c.deinit();
        if (res.has_cycle) detected += 1;
    }
    const total = timer.read();
    const avg_ns = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(iters));
    try std.testing.expect(avg_ns < 15_000_000); // guard
    try std.testing.expect(detected == iters);
    std.debug.print("{s}\n", .{try std.json.stringifyAlloc(std.testing.allocator, .{ .avg_ns = avg_ns }, .{})});
}
