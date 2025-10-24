const std = @import("std");
const seed = @import("src/planner/cost_seed.zig");

// Test dynamic alpha adaptation reacts to stable vs volatile ratio streams.
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorDynamicAlpha; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_AdaptiveEstimatorDynamicAlpha; OWNER=planner; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_075_AdaptiveEstimatorDynamicAlpha" {
    var reg = seed.AdaptiveBiasRegistry{};
    const kind = seed.LogicalOpKind.Scan;
    // Baseline alpha
    const initial_alpha = reg.getAlpha(kind);
    // Feed stable ratios around 1.2 with low variance
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const est = 1000.0;
        const actual = 1200.0 + (if ((i % 2) == 0) 0.0 else 5.0); // tiny jitter
        reg.updateAdaptive(kind, est, actual);
    }
    const alpha_after_stable = reg.getAlpha(kind);
    // Now feed volatile ratios: alternate 0.4x and 1.8x
    i = 0;
    while (i < 30) : (i += 1) {
        const est = 1000.0;
        const actual = if ((i % 2) == 0) 400.0 else 1800.0;
        reg.updateAdaptive(kind, est, actual);
    }
    const alpha_after_volatile = reg.getAlpha(kind);

    // Expect alpha rose after stable phase, then dropped after volatile phase
    try std.testing.expect(alpha_after_stable > initial_alpha);
    try std.testing.expect(alpha_after_volatile < alpha_after_stable);
    // Ensure bounds respected
    try std.testing.expect(alpha_after_volatile >= reg.alpha_min and alpha_after_volatile <= reg.alpha_max);
}
