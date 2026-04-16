const std = @import("std");

// CANARY: REQ=REQ-GQL-021; FEATURE="Query Planner"; ASPECT=PlannerRewritePassVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_021_PlannerRewritePassVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

fn simulateRewritePass(rules: usize) u64 {
    // Simulate a rewrite pipeline scanning a small expression graph applying rules until fixpoint.
    var prng = std.rand.DefaultPrng.init(0x51514E4E4552); // 'PLANNER'
    const rand = prng.random();
    var applied: u64 = 0;
    var iteration: usize = 0;
    while (iteration < 6) : (iteration += 1) {
        var r: usize = 0;
        while (r < rules) : (r += 1) {
            // Each rule has probability of firing; firing cost ~ 250ns with jitter.
            if ((rand.int(u16) & 0x3) == 0) { // 25% chance
                applied += 1;
            }
        }
    }
    return applied; // We only care about loop stability; timing captured outside.
}

test "BenchmarkCANARY_REQ_GQL_021_PlannerRewritePassVarianceEnvelope" {
    const Runs = 28;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const start = std.time.nanoTimestamp();
        _ = simulateRewritePass(120);
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
    try std.testing.expect(cv < 0.18);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.3);
    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"planner_rewrite_pass_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
