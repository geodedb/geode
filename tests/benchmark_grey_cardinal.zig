const std = @import("std");
const geode = @import("geode");
const builders = geode.graph.builders;
const grey = geode.graph.grey_cardinal;

fn buildSynthetic(allocator: std.mem.Allocator, clusters: u32, cluster_size: u32) !builders.Graph {
    var g = builders.Graph.init(allocator);
    // Create clusters connected in a ring, each cluster a small hub-spoke plus internal path to diversify metrics.
    var cluster: u32 = 0;
    var global_base: u32 = 0;
    while (cluster < clusters) : (cluster += 1) {
        const center = global_base;
        g.addNode(center);
        var k: u32 = 1;
        while (k <= cluster_size) : (k += 1) {
            g.addNode(global_base + k);
            _ = g.addEdge(center, global_base + k, 1) catch {};
            _ = g.addEdge(global_base + k, center, 1) catch {};
            if (k > 1) { // path chain among spokes
                _ = g.addEdge(global_base + k - 1, global_base + k, 1) catch {};
                _ = g.addEdge(global_base + k, global_base + k - 1, 1) catch {};
            }
        }
        // connect cluster centers in ring
        if (cluster > 0) {
            const prev_center = global_base - (cluster_size + 1);
            _ = g.addEdge(prev_center, center, 1) catch {};
            _ = g.addEdge(center, prev_center, 1) catch {};
        }
        global_base += cluster_size + 1;
    }
    // close ring
    if (clusters > 1) {
        var last_center: u32 = 0;
        var sum: u32 = 0;
        var c: u32 = 0;
        while (c < clusters) : (c += 1) sum += (cluster_size + 1);
        last_center = sum - (cluster_size + 1);
        _ = g.addEdge(0, last_center, 1) catch {};
        _ = g.addEdge(last_center, 0, 1) catch {};
    }
    return g;
}

test "BenchmarkCANARY_REQ_GQL_067_GreyCardinalComposite" {
    var g = try buildSynthetic(std.testing.allocator, 6, 12); // ~78 nodes
    defer g.deinit();
    var reps: usize = 0;
    var total: u64 = 0;
    while (reps < 3) : (reps += 1) {
        const start = std.time.nanoTimestamp();
        var res = try grey.compute(std.testing.allocator, &g, .{ .normalize_final = true });
        res.deinit(std.testing.allocator);
        const end = std.time.nanoTimestamp();
        total += @as(u64, @intCast(end - start));
    }
    const avg = total / 3;
    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"grey_cardinal_centrality\",\"avg_ns\":{d}}\n", .{avg});
    try std.testing.expect(avg < 2_000_000_000);
}
