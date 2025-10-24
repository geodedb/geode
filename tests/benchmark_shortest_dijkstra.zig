const std = @import("std");
const builders = @import("../src/graph/builders.zig");
const dijkstra = @import("../src/graph/shortest_dijkstra.zig");

// BenchmarkCANARY_REQ_GQL_063_Dijkstra
// Measures average time to compute single-source shortest paths on a synthetic sparse graph.
// Deterministic: fixed PRNG seed, graph shape reproducible.

test "BenchmarkCANARY_REQ_GQL_063_Dijkstra" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var prng = std.rand.DefaultPrng.init(0xD1A5_731A);
    const rand = prng.random();

    const nodes: u32 = 2000; // modest size to keep CI time low
    const edges_per_node: u32 = 6;

    var g = builders.Graph.init(alloc);
    defer g.deinit();

    var id: u32 = 0;
    while (id < nodes) : (id += 1) try g.addNode(id);

    // Random sparse edges with weight 1..10
    id = 0;
    while (id < nodes) : (id += 1) {
        var e: u32 = 0;
        while (e < edges_per_node) : (e += 1) {
            const dst = rand.intRangeLessThan(u32, 0, nodes);
            if (dst == id) continue;
            const w = 1 + rand.intRangeLessThan(u32, 0, 10);
            // ignore errors for duplicate edges
            _ = g.addEdge(id, dst, w) catch {};
        }
    }

    const trials: usize = 12;
    var total_ns: u128 = 0;
    var t: usize = 0;
    while (t < trials) : (t += 1) {
        const src = rand.intRangeLessThan(u32, 0, nodes);
        const start = std.time.nanoTimestamp();
        var res = try dijkstra.compute(alloc, g, src, null);
        const end = std.time.nanoTimestamp();
        total_ns += @as(u128, @intCast(end - start));
        res.deinit(alloc);
    }

    const avg_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(trials));
    // Basic sanity bound: average should be < 50ms (50000000ns)
    try std.testing.expect(avg_ns < 50_000_000.0);

    // Emit JSON metric to stderr to keep stdout clean
    var bw = std.io.bufferedWriter(std.io.getStdErr().writer());
    const w = bw.writer();
    try w.print("{\"metric\":\"dijkstra_avg_ns\",\"value\":{d:.2}}\n", .{avg_ns});
    try bw.flush();
}
