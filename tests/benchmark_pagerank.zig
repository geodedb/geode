const std = @import("std");
const geode = @import("geode");
const builders = geode.graph.builders;
const pr = geode.graph.pagerank;

fn buildGraph(alloc: std.mem.Allocator, n: u32, extra: u32) !builders.Graph {
    var g = builders.Graph.init(alloc);
    var i: u32 = 0;
    while (i < n) : (i += 1) g.addNode(i);
    // Deterministic dense-ish pattern: each node points to next 2 successors mod n plus an extra deterministic edge.
    i = 0;
    while (i < n) : (i += 1) {
        _ = g.addEdge(i, (i + 1) % n, 1) catch {};
        _ = g.addEdge(i, (i + 2) % n, 1) catch {};
        var j: u32 = 0;
        while (j < extra) : (j += 1) {
            const dst = (i * 2654435761 + j * 97) % n; // multiplicative hash for variety
            if (dst != i) _ = g.addEdge(i, dst, 1) catch {};
        }
    }
    return g;
}

test "BenchmarkCANARY_REQ_GQL_067_PageRank" {
    var g = try buildGraph(std.testing.allocator, 300, 1);
    defer g.deinit();
    var reps: usize = 0;
    var total_ns: u64 = 0;
    while (reps < 5) : (reps += 1) {
        const start = std.time.nanoTimestamp();
        var res = try pr.compute(std.testing.allocator, &g, .{ .max_iterations = 40, .epsilon = 1e-9 });
        res.deinit(std.testing.allocator);
        const end = std.time.nanoTimestamp();
        total_ns += @as(u64, @intCast(end - start));
    }
    const avg = total_ns / 5;
    const stderr = std.io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"pagerank\",\"avg_ns\":{d}}\n", .{avg});
    // Expect average under 250ms
    try std.testing.expect(avg < 250_000_000);
}
