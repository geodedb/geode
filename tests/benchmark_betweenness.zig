const std = @import("std");
const geode = @import("geode");
const builders = geode.graph.builders;
const betw = geode.graph.betweenness;

fn buildGrid(allocator: std.mem.Allocator, rows: u32, cols: u32) !builders.Graph {
    var g = builders.Graph.init(allocator);
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            const id = r * cols + c;
            g.addNode(id);
            if (c + 1 < cols) {
                _ = g.addEdge(id, id + 1, 1) catch {};
                _ = g.addEdge(id + 1, id, 1) catch {};
            }
            if (r + 1 < rows) {
                const dn = (r + 1) * cols + c;
                _ = g.addEdge(id, dn, 1) catch {};
                _ = g.addEdge(dn, id, 1) catch {};
            }
        }
    }
    return g;
}

test "BenchmarkCANARY_REQ_GQL_067_Betweenness" {
    var g = try buildGrid(std.testing.allocator, 16, 16); // 256 nodes
    defer g.deinit();
    var reps: usize = 0;
    var total: u64 = 0;
    while (reps < 3) : (reps += 1) {
        const start = std.time.nanoTimestamp();
        var res = try betw.compute(std.testing.allocator, &g, .{ .normalize = true });
        res.deinit(std.testing.allocator);
        const end = std.time.nanoTimestamp();
        total += @as(u64, @intCast(end - start));
    }
    const avg = total / 3;
    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"betweenness_centrality\",\"avg_ns\":{d}}\n", .{avg});
    // Loose bound (algorithm is O(V*(V+E))): ensure under 2s in debug for this size
    try std.testing.expect(avg < 2_000_000_000);
}
