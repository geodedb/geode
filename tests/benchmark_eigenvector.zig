const std = @import("std");
const geode = @import("geode");
const builders = geode.graph.builders;
const eigen = geode.graph.eigenvector;

fn buildGraph(alloc: std.mem.Allocator, n: u32) !builders.Graph {
    var g = builders.Graph.init(alloc);
    var i: u32 = 0;
    while (i < n) : (i += 1) g.addNode(i);
    // Make a deterministic ring plus chords for connectivity influence.
    i = 0;
    while (i < n) : (i += 1) {
        _ = g.addEdge(i, (i + 1) % n, 1) catch {};
        _ = g.addEdge((i + 1) % n, i, 1) catch {}; // bidirectional
        if ((i % 5) == 0) { // periodic chord
            const dst = (i + 7) % n;
            _ = g.addEdge(i, dst, 1) catch {};
            _ = g.addEdge(dst, i, 1) catch {};
        }
    }
    return g;
}

test "BenchmarkCANARY_REQ_GQL_067_Eigenvector" {
    var g = try buildGraph(std.testing.allocator, 350);
    defer g.deinit();
    var reps: usize = 0;
    var total_ns: u64 = 0;
    while (reps < 5) : (reps += 1) {
        const start = std.time.nanoTimestamp();
        var res = try eigen.compute(std.testing.allocator, &g, .{ .max_iterations = 60, .epsilon = 1e-9 });
        res.deinit(std.testing.allocator);
        const end = std.time.nanoTimestamp();
        total_ns += @as(u64, @intCast(end - start));
    }
    const avg = total_ns / 5;
    const stderr = std.io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"eigenvector_centrality\",\"avg_ns\":{d}}\n", .{avg});
    try std.testing.expect(avg < 300_000_000);
}
