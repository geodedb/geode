const std = @import("std");
const estimator_mod = @import("optimizer/selectivity_estimator.zig");

// CANARY: REQ=REQ-GQL-084; FEATURE="SelectivityEstimator"; ASPECT=EstimatorVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_084_EstimatorVarianceEnvelope; OWNER=optimizer; UPDATED=2025-09-23

test "BenchmarkCANARY_REQ_GQL_084_EstimatorVarianceEnvelope" {
    const Runs = 30; // provide stable percentile
    var samples: [Runs]u64 = undefined;
    const allocator = std.testing.allocator;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        var ae = estimator_mod.AdaptiveEstimator.init(allocator, 128);
        defer ae.deinit();
        // Simulate mixed observations (80% key A, 15% key B, 5% random others)
        var i: usize = 0;
        while (i < 1000) : (i += 1) {
            const mod10 = i % 20;
            if (mod10 < 16) {
                try ae.observe("A");
            } else if (mod10 < 19) {
                try ae.observe("B");
            } else {
                var buf: [8]u8 = undefined;
                std.mem.writeInt(u64, &buf, @intCast(i), .little);
                try ae.observe(buf[0..]);
            }
        }
        // Measure estimate + feedback cycle cost for hot key
        const start = std.time.nanoTimestamp();
        const pred = ae.estimate("A");
        // pretend actual selectivity drifted downward slightly
        ae.feedback("A", pred * 0.9);
        const end = std.time.nanoTimestamp();
        samples[r] = @intCast(end - start);
    }
    var sum: f128 = 0;
    for (samples) |v| sum += @as(f128, @floatFromInt(v));
    const mean = sum / @as(f128, samples.len);
    var var_acc: f128 = 0;
    for (samples) |v| {
        const dv = @as(f128, @floatFromInt(v)) - mean;
        var_acc += dv * dv;
    }
    const stddev = std.math.sqrt(var_acc / @as(f128, samples.len));
    const cv = stddev / mean;
    var sorted: [Runs]u64 = undefined;
    @memcpy(&sorted, &samples);
    std.sort.heap(u64, &sorted, {}, comptime std.sort.asc(u64));
    const p95 = sorted[@min(sorted.len - 1, (sorted.len * 95) / 100)];
    try std.testing.expect(cv <= 0.22);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.55);
    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"selectivity_estimator_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
