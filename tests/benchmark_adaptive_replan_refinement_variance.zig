const std = @import("std");
const ar = @import("../src/planner/adaptive_replan.zig");

// CANARY: REQ=REQ-GQL-021; FEATURE="Query Planner"; ASPECT=PlannerAdaptiveReplanRefinementVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_021_PlannerAdaptiveReplanRefinementVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22

fn lcgNext(s: *u64) u64 {
    s.* = s.* *% 2862933555777941757 +% 3037000493;
    return s.*;
}

test "BenchmarkCANARY_REQ_GQL_021_PlannerAdaptiveReplanRefinementVarianceEnvelope" {
    const Runs = 55;
    var samples: [Runs]u64 = undefined;
    var seed: u64 = 0xA55AA55A12345678;

    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        var adapt = ar.AdaptiveReplan.init(180_000, 5); // 18% initial
        const start = std.time.nanoTimestamp();
        var iter: usize = 0;
        while (!adapt.shouldReplan() and iter < 120) : (iter += 1) {
            const expected: u64 = 20_000 + (lcgNext(&seed) % 8000);
            // Introduce mixed bias periods: blocks of mild then heavy deviation
            var deviation: u64 = undefined;
            if ((iter / 15) % 2 == 0) {
                deviation = (lcgNext(&seed) % 2000); // up to 10%
            } else {
                deviation = (lcgNext(&seed) % 7000); // up to ~30%
            }
            const actual: u64 = expected + deviation; // bias upward only to tighten threshold
            adapt.observe(expected, actual);
        }
        const end = std.time.nanoTimestamp();
        samples[r] = @intCast(end - start);
    }

    var sum: f128 = 0;
    for (samples) |v| sum += @as(f128, @floatFromInt(v));
    const mean = sum / @as(f128, @floatFromInt(samples.len));
    var acc: f128 = 0;
    for (samples) |v| {
        const d = @as(f128, @floatFromInt(v)) - mean;
        acc += d * d;
    }
    const variance = acc / @as(f128, @floatFromInt(samples.len));
    const stddev = std.math.sqrt(variance);
    const cv = stddev / mean;
    if (cv > 0.22) return error.VarianceEnvelopeBreached;
}
