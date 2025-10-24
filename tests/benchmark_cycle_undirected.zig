const std = @import("std");
const cud = @import("../src/graph/cycle_detect_undirected.zig");

// BenchmarkCANARY_REQ_GQL_062_CycleUndirected
test "BenchmarkCANARY_REQ_GQL_062_CycleUndirected" {
    var g = cud.SimpleAdj.init(std.testing.allocator);
    defer g.deinit();
    const N: u64 = 800;
    // Build a graph that is mostly a chain with periodic extra edges forming cycles
    for (0..N) |i| {
        const u = @as(u64, i);
        const v = (u + 1) % N; // makes one big cycle logically, but we'll also add chords
        try g.addEdge(u, v);
        if (u % 40 == 0 and u + 5 < N) try g.addEdge(u, u + 5);
    }
    var verts = std.ArrayList(u64).init(std.testing.allocator);
    defer verts.deinit();
    for (0..N) |i| verts.append(@as(u64, i)) catch unreachable;

    const iters: usize = 60;
    var timer = try std.time.Timer.start();
    var detected: usize = 0;
    for (0..iters) |_| {
        const res = try cud.UndirectedCycle.detect(std.testing.allocator, verts.items, @ptrCast(&g), cud.SimpleAdj.neighCtx);
        if (res.cycle) |c| c.deinit();
        if (res.has_cycle) detected += 1;
    }
    const total = timer.read();
    const avg_ns = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(iters));
    try std.testing.expect(avg_ns < 18_000_000);
    try std.testing.expect(detected == iters);
    std.debug.print("{s}\n", .{try std.json.stringifyAlloc(std.testing.allocator, .{ .avg_ns = avg_ns }, .{})});
}
