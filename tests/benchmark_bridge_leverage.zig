const std = @import("std");
const geode = @import("geode");
const builders = geode.graph.builders;
const bridge = @import("../src/graph/centrality_bridge_leverage.zig");

fn buildGraph(allocator: std.mem.Allocator, clusters: u32, cluster_size: u32) !builders.Graph {
    var g = builders.Graph.init(allocator);
    // Create clusters as rings, connect via single hub 0
    g.addNode(0);
    var base: u32 = 1;
    var c: u32 = 0;
    while (c < clusters) : (c += 1) {
        var k: u32 = 0;
        while (k < cluster_size) : (k += 1) g.addNode(base + k);
        var k2: u32 = 0;
        while (k2 < cluster_size) : (k2 += 1) {
            const a = base + k2;
            const b = base + ((k2 + 1) % cluster_size);
            _ = g.addEdge(a, b, 1) catch {};
            _ = g.addEdge(b, a, 1) catch {};
            _ = g.addEdge(0, a, 1) catch {};
            _ = g.addEdge(a, 0, 1) catch {};
        }
        base += cluster_size;
    }
    return g;
}

test "BenchmarkCANARY_REQ_GQL_067_BridgeLeverage" {
    var g = try buildGraph(std.testing.allocator, 8, 20); // 160 + hub
    defer g.deinit();
    var reps: usize = 0;
    var total: u64 = 0;
    while (reps < 3) : (reps += 1) {
        const start = std.time.nanoTimestamp();
        var res = try bridge.compute(std.testing.allocator, &g, .{ .normalize = false });
        res.deinit(std.testing.allocator);
        const end = std.time.nanoTimestamp();
        total += @as(u64, @intCast(end - start));
    }
    const avg = total / 3;
    const stderr = std.io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"bridge_leverage_centrality\",\"avg_ns\":{d}}\n", .{avg});
    try std.testing.expect(avg < 1_800_000_000);
}
