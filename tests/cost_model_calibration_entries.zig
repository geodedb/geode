const std = @import("std");
const seed = @import("../src/planner/cost_seed.zig");
const explain = @import("../src/planner/cost_explain.zig");

// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=CalibrationEntries; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_CostModelCalibrationEntries; OWNER=planner; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_075_CostModelCalibrationEntries" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ops = [_]seed.OpDescriptor{
        .{ .kind = .Scan },
        .{ .kind = .Expand },
        .{ .kind = .Filter, .selectivity = 0.5 },
        .{ .kind = .Project },
    };
    // Derive estimated rows (mirror algorithm) to craft actual rows with controlled perturbation.
    const cfg = seed.EstimatorConfig{};
    var ests = [_]seed.CardinalityEstimate{ undefined, undefined, undefined, undefined };
    ests[0] = seed.estimate(ops[0], &[_]seed.CardinalityEstimate{}, cfg);
    ests[1] = seed.estimate(ops[1], &[_]seed.CardinalityEstimate{ests[0]}, cfg);
    ests[2] = seed.estimate(ops[2], &[_]seed.CardinalityEstimate{ests[1]}, cfg);
    ests[3] = seed.estimate(ops[3], &[_]seed.CardinalityEstimate{ests[2]}, cfg);
    const actual = [_]f64{
        ests[0].rows * 1.10, // +10%
        ests[1].rows * 0.90, // -10%
        ests[2].rows * 1.25, // +25%
        ests[3].rows * 0.80, // -20%
    };
    const json = try explain.explainChainWithCalibration(gpa.allocator(), &ops, &actual, null);
    defer gpa.allocator().free(json);
    // Ensure schema is v2
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema\":\"cost_explain.v2\"") != null);
    // Must contain calibration block with non-zero mape and entries array
    const calib_pos = std.mem.indexOf(u8, json, "\"calibration\":{") orelse return error.NoCalibration;
    _ = calib_pos;
    // entries presence
    try std.testing.expect(std.mem.indexOf(u8, json, "\"entries\":") != null);
    // mape should be >0 due to perturbations
    const mape_key = "\"mape\":";
    const mape_idx = std.mem.indexOf(u8, json, mape_key) orelse return error.MapeMissing;
    // extract substring after mape
    var j: usize = mape_idx + mape_key.len;
    var mape_val: usize = 0;
    while (j < json.len and json[j] >= '0' and json[j] <= '9') : (j += 1) {
        mape_val = mape_val * 10 + (json[j] - '0');
    }
    try std.testing.expect(mape_val > 0);
    // Spot check one entry has abs_pct_err key
    try std.testing.expect(std.mem.indexOf(u8, json, "\"abs_pct_err\":") != null);
}
