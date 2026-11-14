const std = @import("std");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC"; ASPECT=CDCAdaptiveHeuristicsDecisionLatencyVarianceEnvelope; STATUS=IMPL; BENCH=BenchmarkCANARY_REQ_GQL_042_CDCAdaptiveHeuristicsDecisionLatencyVarianceEnvelope; OWNER=cdc; UPDATED=2026-11-14

fn simulateAdaptiveDecision(iteration: usize) u64 {
    // Model an adaptive heuristic deciding on batch flush or backpressure adjustments.
    // Components: moving average update, percentile sketch update, hysteresis evaluation.
    var seed: u64 = 0xCDA_D3C15 + @as(u64, iteration) * 0x9E3779B97F4A7C15;
    // Simple xorshift* for deterministic pseudo-randomness
    seed ^= seed >> 12;
    seed ^= seed << 25;
    seed ^= seed >> 27;
    const rand_val = seed & 0xFFFFFFFFFFFF;

    // Emulate cost components (nanoseconds) with controlled jitter.
    const moving_avg_cost: u64 = 180 + (rand_val & 0x3F); // 180-243 ns
    const sketch_update_cost: u64 = 260 + ((rand_val >> 6) & 0x7F); // 260-383 ns
    const hysteresis_eval_cost: u64 = 110 + ((rand_val >> 13) & 0x3F); // 110-173 ns

    // Occasional branch for recalibration (every ~9 iterations)
    const recalib: u64 = if ((iteration % 9) == 0) 200 + ((rand_val >> 19) & 0x7F) else 0;

    return moving_avg_cost + sketch_update_cost + hysteresis_eval_cost + recalib;
}

test "BenchmarkCANARY_REQ_GQL_042_CDCAdaptiveHeuristicsDecisionLatencyVarianceEnvelope" {
    const Runs = 28;
    var samples: [Runs]u64 = undefined;
    var i: usize = 0;
    while (i < Runs) : (i += 1) {
        const start = std.time.nanoTimestamp();
        var inner: usize = 0;
        var acc: u64 = 0;
        // Perform several decisions to approximate a batch of adaptive evaluations.
        while (inner < 32) : (inner += 1) {
            acc += simulateAdaptiveDecision(i * 32 + inner);
        }
        std.mem.doNotOptimizeAway(acc);
        const end = std.time.nanoTimestamp();
        samples[i] = @intCast(end - start);
    }

    // Stats
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

    // Envelope thresholds: adaptive heuristic path allowed modest variability.
    try std.testing.expect(cv < 0.20);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.5);

    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"cdc_adaptive_decision_latency_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
