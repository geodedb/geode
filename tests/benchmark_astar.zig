const std = @import("std");
const builders = @import("../src/graph/builders.zig");
const astar = @import("../src/graph/shortest_astar.zig");

// BenchmarkCANARY_REQ_GQL_063_AStar
// Measure average A* run time on a random directed sparse graph. Heuristic = zero (degenerates to Dijkstra upper bound).
// Deterministic via fixed PRNG seed.
test "BenchmarkCANARY_REQ_GQL_063_AStar" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var prng = std.rand.DefaultPrng.init(0xA57A7000);
    const rand = prng.random();

    const nodes: u32 = 1800;
    const edges_per: u32 = 5;
    var g = builders.Graph.init(alloc);
    defer g.deinit();
    var id: u32 = 0;
    while (id < nodes) : (id += 1) g.addNode(id);
    id = 0;
    while (id < nodes) : (id += 1) {
        var e: u32 = 0;
        while (e < edges_per) : (e += 1) {
            const dst = rand.intRangeLessThan(u32, 0, nodes);
            if (dst == id) continue;
            _ = g.addEdge(id, dst, 1 + rand.intRangeLessThan(u32, 0, 8)) catch {};
        }
    }
    const trials: usize = 10;
    var total: u128 = 0;
    var t: usize = 0;
    while (t < trials) : (t += 1) {
        const s = rand.intRangeLessThan(u32, 0, nodes);
        const tgt = rand.intRangeLessThan(u32, 0, nodes);
        const start_ns = std.time.nanoTimestamp();
        var res = try astar.compute(alloc, g, s, tgt, null); // null heuristic (worst case)
        const end_ns = std.time.nanoTimestamp();
        total += @as(u128, @intCast(end_ns - start_ns));
        res.deinit(alloc);
    }
    const avg = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(trials));
    // Expect under 60ms
    try std.testing.expect(avg < 60_000_000.0);
    var bw = std.Io.bufferedWriter(std.Io.getStdErr().writer());
    const w = bw.writer();
    try w.print("{\"metric\":\"astar_avg_ns\",\"value\":{d:.2}}\n", .{avg});
    try bw.flush();
}
