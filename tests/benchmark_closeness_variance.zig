const std = @import("std");
const geode = @import("geode");
const closeness = geode.graph.closeness;
const builders = geode.graph.builders;

// CANARY: REQ=REQ-GQL-067; FEATURE="Centrality"; ASPECT=ClosenessVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_067_ClosenessVarianceEnvelope; OWNER=graph; UPDATED=2025-09-21

fn buildMesh(allocator: std.mem.Allocator, n: u32) !builders.Graph {
    var g = builders.Graph.init(allocator);
    var i: u32 = 0;
    while (i < n) : (i += 1) g.addNode(i);
    i = 0;
    while (i < n) : (i += 1) {
        var j: u32 = i + 1;
        while (j < n) : (j += 1) {
            _ = g.addEdge(i, j, 1) catch {};
            _ = g.addEdge(j, i, 1) catch {};
        }
    }
    return g;
}

test "BenchmarkCANARY_REQ_GQL_067_ClosenessVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var g = try buildMesh(allocator, 42);
    defer g.deinit();

    const Runs = 28;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const start = std.time.nanoTimestamp();
        var res = try closeness.compute(allocator, &g, .{ .harmonic = true });
        res.deinit(allocator);
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

    // Thresholds: CV < 0.20, p95 < 2.5x mean
    try std.testing.expect(cv < 0.20);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.5);

    const stderr = std.io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"closeness_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
