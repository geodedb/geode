const std = @import("std");
const geode = @import("geode");
const seed = geode.cost_seed;
const calib = geode.cost_model_calibration;

// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorVarianceAutoCalibration; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_AutoCalibrationAdjustsAlpha; OWNER=planner; UPDATED=2025-09-26

test "TestCANARY_REQ_GQL_075_AutoCalibrationAdjustsAlpha" {
    var reg = seed.AdaptiveBiasRegistry{};
    // Drive stable (Scan) and volatile (Expand) patterns to exercise dynamic alpha bounds.
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        reg.updateAdaptive(.Scan, 1000, 1000 + @as(f64, @floatFromInt(i % 2))); // near constant
        // Expand oscillates widely
        const delta: f64 = @floatFromInt((i * 97) % 800);
        reg.updateAdaptive(.Expand, 1000, 1000 + delta);
    }
    const report = calib.VarianceAutoCalibrator.calibrate(&reg);
    // Expect at least one volatile classification and one stable.
    try std.testing.expect(report.volatile_count > 0);
    try std.testing.expect(report.stable > 0);
    // Average alpha must fall within configured bounds.
    try std.testing.expect(report.avg_alpha >= 0.10 and report.avg_alpha <= 0.50);
}
