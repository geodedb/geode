const std = @import("std");
const seed = @import("src/planner/cost_seed.zig");

// Validate that using estimateChainWithBias after applying observed actuals reduces aggregate absolute percentage error.
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=PlannerAdaptiveBiasApplication; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_PlannerAdaptiveBiasApplication; OWNER=planner; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_075_PlannerAdaptiveBiasApplication" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var reg = seed.AdaptiveBiasRegistry{};
    const cfg = seed.EstimatorConfig{ .adaptive_alpha = 0.35 };
    const ops = [_]seed.OpDescriptor{
        .{ .kind = .Scan },
        .{ .kind = .Expand },
        .{ .kind = .Filter, .selectivity = 0.25 },
        .{ .kind = .Aggregate },
    };

    // First pass unbiased estimates
    var prev: ?seed.CardinalityEstimate = null;
    var est_first = [_]f64{0} ** ops.len;
    for (ops, 0..) |op, idx| {
        const slice: []const seed.CardinalityEstimate = if (prev) |p| &[_]seed.CardinalityEstimate{p} else &[_]seed.CardinalityEstimate{};
        const ce = seed.estimate(op, slice, cfg);
        est_first[idx] = ce.rows;
        prev = ce;
    }

    // Synthesize actuals with mixed biases
    var actuals = [_]f64{0} ** ops.len;
    actuals[0] = est_first[0] * 1.4; // underestimation
    actuals[1] = est_first[1] * 0.65; // overestimation
    actuals[2] = est_first[2] * 1.1; // slight under
    actuals[3] = est_first[3] * 0.55; // strong overestimation

    // Compute baseline MAPE
    var mape1: f64 = 0;
    for (est_first, 0..) |e, i| {
        const a = actuals[i];
        const diff = if (e > a) e - a else a - e;
        mape1 += diff / a;
    }
    mape1 /= @as(f64, @floatFromInt(ops.len));

    // Update registry with observations
    for (ops, 0..) |op, i| reg.update(op.kind, est_first[i], actuals[i], cfg.adaptive_alpha);

    // Second pass biased estimates via chain helper
    const chain = try seed.estimateChainWithBias(alloc, &reg, &ops, cfg);
    defer alloc.free(chain);

    var mape2: f64 = 0;
    for (chain, 0..) |c, i| {
        const a = actuals[i];
        const diff = if (c.rows > a) c.rows - a else a - c.rows;
        mape2 += diff / a;
    }
    mape2 /= @as(f64, @floatFromInt(ops.len));

    // Expect improved or equal MAPE (prefer strictly less; allow equality for edge rounding)
    try std.testing.expect(mape2 <= mape1);
    try std.testing.expect(mape1 - mape2 > 0.0);
}
