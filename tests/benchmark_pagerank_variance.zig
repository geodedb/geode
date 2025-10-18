const std = @import("std");
const geode = @import("geode");
const pr = geode.graph.pagerank;

// CANARY: REQ=REQ-GQL-067; FEATURE="Centrality"; ASPECT=PageRankVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_067_PageRankVarianceEnvelope; OWNER=graph; UPDATED=2025-09-21

test "BenchmarkCANARY_REQ_GQL_067_PageRankVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Build a small deterministic graph that exercises convergence (star + cycle mix)
    var g = try pr.Graph.init(allocator, 0);
    defer g.deinit();
    // center 0 -> leaves 1..9, add cycle among 1..4
    var i: usize = 1;
    while (i < 10) : (i += 1) try g.addEdge(0, @intCast(i));
    try g.addEdge(1, 2);
    try g.addEdge(2, 3);
    try g.addEdge(3, 4);
    try g.addEdge(4, 1);
    // Add some backlinks to center to avoid dangling sinks
    try g.addEdge(5, 0);
    try g.addEdge(6, 0);
    try g.addEdge(7, 0);

    const Runs = 48;
    var samples: [Runs]u64 = undefined;
    var idx: usize = 0;
    while (idx < Runs) : (idx += 1) {
        const start = std.time.nanoTimestamp();
        var result = try pr.compute(allocator, &g, .{ .damping = 0.85, .epsilon = 1e-7, .max_iters = 80 });
        defer result.deinit(allocator);
        const end = std.time.nanoTimestamp();
        samples[idx] = @intCast(end - start);
    }

    var sum: f128 = 0;
    for (samples) |s| sum += @as(f128, @floatFromInt(s));
    const mean = sum / @as(f128, samples.len);
    var var_sum: f128 = 0;
    for (samples) |s| {
        const dv = @as(f128, @floatFromInt(s)) - mean;
        var_sum += dv * dv;
    }
    const stddev = std.math.sqrt(var_sum / @as(f128, samples.len));
    const cv = stddev / mean; // coefficient of variation

    // compute p95
    var tmp: [Runs]u64 = undefined;
    for (samples, 0..) |s, j| tmp[j] = s;
    std.sort.heap(u64, &tmp, {}, comptime std.sort.asc(u64));
    const p95 = tmp[@min(tmp.len - 1, (tmp.len * 95) / 100)];

    // Guard thresholds (tune later): CV < 0.18, p95 < 2.5x mean
    try std.testing.expect(cv < 0.18);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.5);

    const stderr = std.io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"pagerank_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
