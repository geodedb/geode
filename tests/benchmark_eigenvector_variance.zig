const std = @import("std");
const geode = @import("geode");
const eig = geode.graph.eigenvector;
const builders = geode.graph.builders;

// CANARY: REQ=REQ-GQL-067; FEATURE="Centrality"; ASPECT=EigenvectorVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_067_EigenvectorVarianceEnvelope; OWNER=graph; UPDATED=2025-09-21

fn buildRing(ally: std.mem.Allocator, n: u32) !builders.Graph {
    var g = builders.Graph.init(ally);
    var i: u32 = 0;
    while (i < n) : (i += 1) g.addNode(i);
    i = 0;
    while (i < n) : (i += 1) {
        const j = (i + 1) % n;
        _ = g.addEdge(i, j, 1) catch {};
        _ = g.addEdge(j, i, 1) catch {};
    }
    return g;
}

test "BenchmarkCANARY_REQ_GQL_067_EigenvectorVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    var g = try buildRing(ally, 96);
    defer g.deinit();

    const Runs = 30;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const start = std.time.nanoTimestamp();
        var res = try eig.compute(ally, &g, .{ .tolerance = 1e-8, .max_iters = 120 });
        res.deinit(ally);
        const end = std.time.nanoTimestamp();
        samples[r] = @intCast(end - start);
    }

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
    for (samples, 0..) |s, i| sorted[i] = s;
    std.sort.heap(u64, &sorted, {}, comptime std.sort.asc(u64));
    const p95 = sorted[@min(sorted.len - 1, (sorted.len * 95) / 100)];

    // Thresholds: CV < 0.18, p95 < 2.4x mean
    try std.testing.expect(cv < 0.18);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.4);

    const stderr = std.io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"eigenvector_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
