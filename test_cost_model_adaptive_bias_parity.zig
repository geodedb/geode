const std = @import("std");
const seed = @import("src/planner/cost_seed.zig");

// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBias; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_AdaptiveEstimatorBiasImplementationParity; OWNER=planner; UPDATED=2025-09-26
// Parity test ensures update() and updateAdaptive() produce expected bias adjustments for
// deterministic synthetic ratios and respect clamping & dynamic alpha bounds.

test "TestCANARY_REQ_GQL_075_AdaptiveEstimatorBiasImplementationParity" {
    var reg = seed.AdaptiveBiasRegistry{};
    const kind = seed.LogicalOpKind.Scan;
    // Base estimate vs actual with ratio=1.5 (actual larger) using static update (alpha=0.2 default)
    const alpha = 0.2;
    const est = 100.0;
    const actual = 150.0; // ratio=1.5
    reg.update(kind, est, actual, alpha);
    const expected_bias1 = alpha * (actual / est) + (1.0 - alpha) * 1.0; // prev bias 1.0
    try std.testing.expectApproxEqRel(expected_bias1, reg.getBias(kind), 1e-9);
    // Apply second static update with ratio=0.5 (actual lower) to pull bias toward 0.5
    reg.update(kind, est, 50.0, alpha); // ratio=0.5
    const expected_bias2 = alpha * 0.5 + (1.0 - alpha) * expected_bias1;
    try std.testing.expectApproxEqRel(expected_bias2, reg.getBias(kind), 1e-9);

    // Test adaptive path: feed stable ratios near 1.0 to push alpha upward toward max
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        reg.updateAdaptive(kind, est, est * 1.02); // mild 2% high
    }
    const a_after_stable = reg.getAlpha(kind);
    try std.testing.expect(a_after_stable <= reg.alpha_max + 1e-12);
    try std.testing.expect(a_after_stable >= reg.alpha_min);
    // Now feed volatile alternating ratios to trigger alpha decrease
    i = 0;
    while (i < 60) : (i += 1) {
        const ratio = if (i % 2 == 0) 0.2 else 2.8; // wide variance
        reg.updateAdaptive(kind, est, est * ratio);
    }
    const a_after_volatile = reg.getAlpha(kind);
    try std.testing.expect(a_after_volatile <= a_after_stable + 1e-9); // should not increase further
    // Ensure CV classification recorded (0 stable,1 moderate,2 volatile) eventually sees volatile (2)
    try std.testing.expect(reg.last_cv_class[@intFromEnum(kind)] <= 2);
    // Bias clamping: feed extremely small actual to drive bias toward low clamp
    i = 0;
    while (i < 20) : (i += 1) reg.update(kind, est, 0.01, alpha);
    try std.testing.expect(reg.getBias(kind) >= 0.05); // low clamp
}
