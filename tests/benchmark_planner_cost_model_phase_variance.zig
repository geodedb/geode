const std = @import("std");
const phase_timing = @import("../src/planner/phase_timing.zig");

fn lcgNext(seed: *u64) u64 {
    seed.* = seed.* *% 6364136223846793005 +% 1;
    return seed.*;
}

// CANARY: REQ=REQ-GQL-021; FEATURE="Query Planner"; ASPECT=PlannerCostModelPhaseVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_021_PlannerCostModelPhaseVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

fn statsCV(samples: []const u64) f128 {
    var sum: f128 = 0;
    for (samples) |v| sum += @as(f128, @floatFromInt(v));
    const mean = sum / @as(f128, @floatFromInt(samples.len));
    var var_acc: f128 = 0;
    for (samples) |v| {
        const diff = @as(f128, @floatFromInt(v)) - mean;
        var_acc += diff * diff;
    }
    const variance = var_acc / @as(f128, @floatFromInt(samples.len));
    const stddev = std.math.sqrt(variance);
    return stddev / mean;
}

test "BenchmarkCANARY_REQ_GQL_021_PlannerCostModelPhaseVarianceEnvelope" {
    const Runs = 40;
    var rewrite_samples: [Runs]u64 = undefined;
    var card_samples: [Runs]u64 = undefined;
    var cost_samples: [Runs]u64 = undefined;
    var r: u64 = 0x1234_5678_9abc_def0;

    var run: usize = 0;
    while (run < Runs) : (run += 1) {
        var timings: phase_timing.PhaseTimings = .{};
        var timer = phase_timing.PhaseTimer.init(&timings);
        // Simulate each phase with deterministic pseudo-random workload loops.
        timer.begin(.rewrite);
        var i: usize = 0; // rewrite loop
        const rewrite_iters = 50 + @as(usize, @intCast(lcgNext(&r) % 50));
        while (i < rewrite_iters) : (i += 1) {
            // lightweight hash mixing
            _ = lcgNext(&r);
        }
        timer.end();

        timer.begin(.cardinality);
        i = 0;
        const card_iters = 30 + @as(usize, @intCast(lcgNext(&r) % 40));
        while (i < card_iters) : (i += 1) {
            _ = lcgNext(&r) & 0xFFFF;
        }
        timer.end();

        timer.begin(.cost_eval);
        i = 0;
        const cost_iters = 20 + @as(usize, @intCast(lcgNext(&r) % 30));
        while (i < cost_iters) : (i += 1) {
            _ = lcgNext(&r) ^ (lcgNext(&r) >> 7);
        }
        timer.end();
        rewrite_samples[run] = timings.rewrite_ns;
        card_samples[run] = timings.cardinality_ns;
        cost_samples[run] = timings.cost_eval_ns;
    }

    const cv_rewrite = statsCV(&rewrite_samples);
    const cv_card = statsCV(&card_samples);
    const cv_cost = statsCV(&cost_samples);
    // Threshold: hot phases CV ≤0.18
    if (cv_rewrite > 0.18 or cv_card > 0.18 or cv_cost > 0.18) {
        std.debug.print("VARIANCE_FAIL PlannerCostModelPhaseVarianceEnvelope rewrite_cv={:.4} card_cv={:.4} cost_cv={:.4}\n", .{ cv_rewrite, cv_card, cv_cost });
        return error.VarianceExceeded;
    }
    std.debug.print("VARIANCE_OK PlannerCostModelPhaseVarianceEnvelope rewrite_cv={:.4} card_cv={:.4} cost_cv={:.4}\n", .{ cv_rewrite, cv_card, cv_cost });
}
