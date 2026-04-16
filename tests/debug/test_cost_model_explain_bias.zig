const std = @import("std");
const seed = @import("src/planner/cost_seed.zig");
const explain = @import("src/planner/cost_explain.zig");

// Test bias explain JSON includes bias field and snapshot.
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainJSONBiasFactors; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_ExplainJSONBiasFactors; OWNER=planner; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_075_ExplainJSONBiasFactors" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var reg = seed.AdaptiveBiasRegistry{};
    const ops = [_]seed.OpDescriptor{ .{ .kind = .Scan }, .{ .kind = .Expand }, .{ .kind = .Filter, .selectivity = 0.2 } };
    // Simulate one feedback cycle updating biases (different actuals to shift bias)
    var est_first = [_]f64{0} ** ops.len;
    var prev_cards: [1]seed.CardinalityEstimate = undefined;
    var prev_len: usize = 0;
    var i: usize = 0;
    const cfg = seed.EstimatorConfig{};
    while (i < ops.len) : (i += 1) {
        const slice = if (prev_len == 0) prev_cards[0..0] else prev_cards[0..1];
        const c = seed.estimate(ops[i], slice, cfg);
        est_first[i] = c.rows;
        prev_cards[0] = c;
        prev_len = 1;
    }
    // Actuals create bias adjustments
    const actuals = [_]f64{ est_first[0] * 1.3, est_first[1] * 0.7, est_first[2] * 1.1 };
    i = 0;
    while (i < ops.len) : (i += 1) reg.update(ops[i].kind, est_first[i], actuals[i], 0.25);

    const json = try explain.explainChainWithBias(alloc, &ops, &reg);
    defer alloc.free(json);
    // Basic assertions
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema\":\"cost_explain.v3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bias\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bias_snapshot\":[") != null);
}
