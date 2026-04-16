const std = @import("std");
const geode = @import("geode");
const builders = geode.graph.builders;
const betw = geode.graph.betweenness;

// CANARY: REQ=REQ-GQL-067; FEATURE="Centrality"; ASPECT=BetweennessVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_067_BetweennessVarianceEnvelope; OWNER=graph; UPDATED=2025-09-21

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

test "BenchmarkCANARY_REQ_GQL_067_BetweennessVarianceEnvelope" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var g = try buildGrid(allocator, 12, 12); // 144 nodes, moderate for variance run
    defer g.deinit();

    const Runs = 32; // enough samples for variance estimate
    var samples: [Runs]u64 = undefined;

    var i: usize = 0;
    while (i < Runs) : (i += 1) {
        const start = std.time.nanoTimestamp();
        var res = try betw.compute(allocator, &g, .{ .normalize = true });
        res.deinit(allocator);
        const end = std.time.nanoTimestamp();
        samples[i] = @intCast(end - start);
    }

    // stats (f128 for precision like pagerank variance)
    var sum: f128 = 0;
    for (samples) |s| sum += @as(f128, @floatFromInt(s));
    const mean = sum / @as(f128, samples.len);
    var var_acc: f128 = 0;
    for (samples) |s| {
        const dv = @as(f128, @floatFromInt(s)) - mean;
        var_acc += dv * dv;
    }
    const stddev = std.math.sqrt(var_acc / @as(f128, samples.len));
    const cv = stddev / mean;

    var sorted: [Runs]u64 = undefined;
    for (samples, 0..) |s, idx| sorted[idx] = s;
    std.sort.heap(u64, &sorted, {}, comptime std.sort.asc(u64));
    const p95 = sorted[@min(sorted.len - 1, (sorted.len * 95) / 100)];

    // Thresholds: CV < 0.20, p95 < 2.5x mean (align w/ PageRank envelope looseness)
    try std.testing.expect(cv < 0.20);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.5);

    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"betweenness_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
