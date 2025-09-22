const std = @import("std");
const seed = @import("../src/planner/cost_seed.zig");
const explain = @import("../src/planner/cost_explain.zig");

// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainJSON; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_CostModelExplainJSON; OWNER=planner; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_075_CostModelExplainJSON" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ops = [_]seed.OpDescriptor{
        .{ .kind = .Scan },
        .{ .kind = .Expand },
        .{ .kind = .Filter, .selectivity = 0.25 },
        .{ .kind = .Limit },
    };
    const json = try explain.explainChain(gpa.allocator(), &ops);
    defer gpa.allocator().free(json);
    // Basic structural checks
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema\":\"cost_explain.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ops\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"row_estimate_final\":") != null);
    // Semantics: filter row estimate should appear before limit and not exceed expand.
    const filter_pos = std.mem.indexOf(u8, json, "\"kind\":\"Filter\"") orelse return error.FilterMissing;
    const expand_pos = std.mem.indexOf(u8, json, "\"kind\":\"Expand\"") orelse return error.ExpandMissing;
    try std.testing.expect(filter_pos > expand_pos);
}

test "TestCANARY_REQ_GQL_075_CostModelCardinalityCalibrationFeedback" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ops = [_]seed.OpDescriptor{ .{ .kind = .Scan }, .{ .kind = .Expand }, .{ .kind = .Filter, .selectivity = 0.5 } };
    // Derive actual rows by perturbing estimates; we don't know estimates beforehand so we call explainChainWithCalibration.
    // We'll approximate actual rows by applying deterministic multipliers to a second pass of estimated rows for simplicity.
    // First compute estimates only.
    const est_only_json = try explain.explainChain(gpa.allocator(), &ops);
    defer gpa.allocator().free(est_only_json);
    // We cannot parse JSON cheaply here without extra code; instead run estimation logic again replicating internal algorithm.
    const cfg = seed.EstimatorConfig{};
    var ests = [_]seed.CardinalityEstimate{ undefined, undefined, undefined };
    ests[0] = seed.estimate(ops[0], &[_]seed.CardinalityEstimate{}, cfg);
    ests[1] = seed.estimate(ops[1], &[_]seed.CardinalityEstimate{ests[0]}, cfg);
    ests[2] = seed.estimate(ops[2], &[_]seed.CardinalityEstimate{ests[1]}, cfg);
    const actual_rows = [_]f64{ ests[0].rows * 0.95, ests[1].rows * 1.10, ests[2].rows * 1.05 };
    const json = try explain.explainChainWithCalibration(gpa.allocator(), &ops, &actual_rows, null);
    defer gpa.allocator().free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema\":\"cost_explain.v2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"calibration\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mape\":") != null);
}
