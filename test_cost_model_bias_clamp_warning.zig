const std = @import("std");
const seed = @import("src/planner/cost_seed.zig");
const explain = @import("src/planner/cost_explain.zig");

// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBiasClampWarning; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_AdaptiveEstimatorBiasClampWarning; OWNER=planner; UPDATED=2025-09-22
// This test exercises clamp saturation: push bias below lower bound repeatedly to trigger LOW_CLAMP warning,
// then push high bound to ensure HIGH_CLAMP triggers, verifying warnings appear in explain v4 JSON.
// Strategy: For a chosen kind (Filter) feed alternating extreme ratios forcing bias to clamp to min or max.

fn driveLowClamp(reg: *seed.AdaptiveBiasRegistry, kind: seed.LogicalOpKind, iterations: usize) void {
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Force a very small ratio to drive bias toward 0 then clamp at 0.05
        reg.updateAdaptive(kind, 1000.0, 1.0);
    }
}

fn driveHighClamp(reg: *seed.AdaptiveBiasRegistry, kind: seed.LogicalOpKind, iterations: usize) void {
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Force huge ratio to drive bias toward >20 then clamp at 20.0
        reg.updateAdaptive(kind, 1000.0, 1_000_000.0);
    }
}

test "TestCANARY_REQ_GQL_075_AdaptiveEstimatorBiasClampWarning" {
    var reg = seed.AdaptiveBiasRegistry{};
    const kind = seed.LogicalOpKind.Filter;
    // Trigger low clamp warning
    driveLowClamp(&reg, kind, reg.clamp_warning_threshold + 1);
    try std.testing.expect(reg.low_clamp_warning[@intFromEnum(kind)]);
    // Now move bias off clamp to reset warnings
    reg.updateAdaptive(kind, 1000.0, 1000.0); // neutral ratio resets streaks
    try std.testing.expect(!reg.low_clamp_warning[@intFromEnum(kind)]);
    // Trigger high clamp warning
    driveHighClamp(&reg, kind, reg.clamp_warning_threshold + 2);
    try std.testing.expect(reg.high_clamp_warning[@intFromEnum(kind)]);

    // Build explain JSON and ensure warnings surface
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const allocator = gpa.allocator();

    const ops = [_]seed.OpDescriptor{.{ .kind = kind }};
    const json_bytes = try explain.explainChainUnifiedV4(allocator, &ops, &reg);
    defer allocator.free(json_bytes);
    const json = json_bytes;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bias_clamp_warnings\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "HIGH_CLAMP(Filter)") != null);
}
