const std = @import("std");
const ar = @import("../src/planner/adaptive_replan.zig");

fn lcgNext(seed_ptr: *u64) u64 {
    seed_ptr.* = seed_ptr.* *% 6364136223846793005 +% 1;
    return seed_ptr.*;
}

// CANARY: REQ=REQ-GQL-021; FEATURE="Query Planner"; ASPECT=PlannerAdaptiveReplanVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_021_PlannerAdaptiveReplanVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

test "BenchmarkCANARY_REQ_GQL_021_PlannerAdaptiveReplanVarianceEnvelope" {
    const Runs = 50;
    var samples: [Runs]u64 = undefined;
    var seed: u64 = 0x5555AAAAFFFF0001;

    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        var adapt = ar.AdaptiveReplan.init(120_000, 5); // 12% threshold
        const start = std.time.nanoTimestamp();
        var iter: usize = 0;
        while (!adapt.shouldReplan() and iter < 100) : (iter += 1) {
            const expected: u64 = 10_000 + (lcgNext(&seed) % 5000);
            // simulate actual with controlled deviation ramping
            var deviation: u64 = undefined;
            if (iter < 20) {
                deviation = lcgNext(&seed) % 500;
            } else {
                deviation = lcgNext(&seed) % 4000;
            }
            const actual: u64 = if ((iter & 1) == 0) expected + deviation else expected - deviation;
            adapt.observe(expected, actual);
        }
        const end = std.time.nanoTimestamp();
        samples[r] = @intCast(end - start);
    }

    // compute variance stats
    var sum: f128 = 0;
    for (samples) |v| sum += @as(f128, @floatFromInt(v));
    const mean = sum / @as(f128, @floatFromInt(samples.len));
    var var_acc: f128 = 0;
    for (samples) |v| {
        const d = @as(f128, @floatFromInt(v)) - mean;
        var_acc += d * d;
    }
    const variance = var_acc / @as(f128, @floatFromInt(samples.len));
    const stddev = std.math.sqrt(variance);
    const cv = stddev / mean;

    // Threshold CV ≤0.22
    if (cv > 0.22) {
        std.debug.print("VARIANCE_FAIL PlannerAdaptiveReplanVarianceEnvelope cv={:.4}\n", .{cv});
        return error.VarianceExceeded;
    }
    std.debug.print("VARIANCE_OK PlannerAdaptiveReplanVarianceEnvelope cv={:.4}\n", .{cv});
}
