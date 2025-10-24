const std = @import("std");
const seed = @import("src/planner/cost_seed.zig");

// Test adaptive bias reduces MAPE after updating registry with observed actual rows.
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBias; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_AdaptiveEstimatorBias; OWNER=planner; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_075_AdaptiveEstimatorBias" {
    var reg = seed.AdaptiveBiasRegistry{};
    const cfg = seed.EstimatorConfig{ .adaptive_alpha = 0.3 };
    // Define a small operator chain: Scan -> Expand -> Filter -> Limit
    const ops = [_]seed.OpDescriptor{
        .{ .kind = .Scan },
        .{ .kind = .Expand },
        .{ .kind = .Filter, .selectivity = 0.15 },
        .{ .kind = .Limit },
    };
    // Pass 1 estimates & synthesize actuals with systematic bias (e.g. actual = est * k)
    var ests = [_]f64{0} ** ops.len;
    var prev_cards: [4]seed.CardinalityEstimate = undefined; // scratch for chaining
    var prev_len: usize = 0;
    var i: usize = 0;
    while (i < ops.len) : (i += 1) {
        const slice = if (prev_len == 0) prev_cards[0..0] else prev_cards[0..1];
        const c = seed.estimate(ops[i], slice, cfg);
        ests[i] = c.rows;
        prev_cards[0] = c;
        prev_len = 1;
    }
    // Introduce biases: Scan underestimates (actual=1.4x), Expand overestimates (actual=0.6x), Filter accurate (1.0), Limit reduces to min(est, 100) but actual slightly less (0.9x)
    var actuals = [_]f64{0} ** ops.len;
    actuals[0] = ests[0] * 1.4;
    actuals[1] = ests[1] * 0.6;
    actuals[2] = ests[2] * 1.0;
    actuals[3] = @min(ests[3], 100.0) * 0.9;
    // Compute MAPE pass1
    var mape1: f64 = 0;
    for (ests, 0..) |e, idx| {
        const a = actuals[idx];
        const diff = if (e > a) e - a else a - e;
        mape1 += diff / a;
    }
    mape1 = mape1 / @as(f64, @floatFromInt(ops.len));
    // Update registry with observations
    i = 0;
    while (i < ops.len) : (i += 1) {
        reg.update(ops[i].kind, ests[i], actuals[i], cfg.adaptive_alpha);
    }
    // Pass 2 estimates with bias applied
    prev_len = 0;
    i = 0;
    var ests2 = [_]f64{0} ** ops.len;
    while (i < ops.len) : (i += 1) {
        const slice = if (prev_len == 0) prev_cards[0..0] else prev_cards[0..1];
        const base = seed.estimate(ops[i], slice, cfg);
        const biased_rows = reg.apply(ops[i].kind, base.rows);
        ests2[i] = biased_rows;
        prev_cards[0] = .{ .rows = biased_rows, .confidence = base.confidence };
        prev_len = 1;
    }
    var mape2: f64 = 0;
    for (ests2, 0..) |e, idx| {
        const a = actuals[idx];
        const diff = if (e > a) e - a else a - e;
        mape2 += diff / a;
    }
    mape2 = mape2 / @as(f64, @floatFromInt(ops.len));
    // Expect improvement (mape2 < mape1) with some tolerance margin
    try std.testing.expect(mape2 < mape1);
}
