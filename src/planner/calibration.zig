const std = @import("std");
const seed = @import("cost_seed.zig");

// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorVarianceAutoCalibration; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_AutoCalibrationAdjustsAlpha; OWNER=planner; UPDATED=2025-09-26
// Variance auto-calibration wrapper. Leverages AdaptiveBiasRegistry variance stats (last_cv + class) to
// produce a summary report and recommended alpha adjustment hints. The underlying dynamic alpha adjustments
// already occur in updateAdaptive(); this layer supplies governance-friendly reporting & potential future policy hooks.

pub const CalibrationReport = struct {
    stable: usize = 0,
    moderate: usize = 0,
    volatile_count: usize = 0,
    avg_alpha: f64 = 0.0,
    avg_cv: f64 = 0.0,
    // Hint flags: consider expanding bounds or tightening smoothing.
    recommend_raise_alpha_ceiling: bool = false,
    recommend_lower_alpha_floor: bool = false,
};

pub const VarianceAutoCalibrator = struct {
    pub fn calibrate(reg: *const seed.AdaptiveBiasRegistry) CalibrationReport {
        var rep: CalibrationReport = .{};
        const count = seed.AdaptiveBiasRegistry.KIND_COUNT;
        var alpha_sum: f64 = 0;
        var cv_sum: f64 = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            alpha_sum += reg.dyn_alpha[i];
            cv_sum += reg.last_cv[i];
            const class = reg.last_cv_class[i];
            switch (class) {
                0 => rep.stable += 1,
                1 => rep.moderate += 1,
                2 => rep.volatile_count += 1,
                else => {},
            }
            // Hints: if most stable and near alpha_max, consider raising ceiling.
            if (class == 0 and reg.dyn_alpha[i] >= reg.alpha_max - 0.0001) {
                rep.recommend_raise_alpha_ceiling = true;
            }
            if (class == 2 and reg.dyn_alpha[i] <= reg.alpha_min + 0.0001) {
                rep.recommend_lower_alpha_floor = true;
            }
        }
        if (count > 0) {
            rep.avg_alpha = alpha_sum / @as(f64, @floatFromInt(count));
            rep.avg_cv = cv_sum / @as(f64, @floatFromInt(count));
        }
        return rep;
    }
};

test "basic calibration report aggregates counts" {
    var reg = seed.AdaptiveBiasRegistry{}; // neutral initial state (all class=0)
    // Simulate some updates to produce variance: high variance for Expand, low for Scan.
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        reg.updateAdaptive(.Scan, 1000, 1000 + @as(f64, @floatFromInt(i % 3))); // near stable
        reg.updateAdaptive(.Expand, 1000, 1000 + @as(f64, @floatFromInt((i * 37) % 400))); // more variance
    }
    const rep = VarianceAutoCalibrator.calibrate(&reg);
    try std.testing.expect(rep.stable + rep.moderate + rep.volatile_count == seed.AdaptiveBiasRegistry.KIND_COUNT);
}
