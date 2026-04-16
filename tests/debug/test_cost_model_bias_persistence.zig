const std = @import("std");
const seed = @import("src/planner/cost_seed.zig");

// Test serialization/deserialization round-trip for adaptive bias registry.
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBiasPersistence; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_AdaptiveEstimatorBiasPersistence; OWNER=planner; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_075_AdaptiveEstimatorBiasPersistence" {
    var reg = seed.AdaptiveBiasRegistry{};
    const cfg = seed.EstimatorConfig{ .adaptive_alpha = 0.4 };
    // Create a simple chain and apply updates to shift biases away from 1.0
    const ops = [_]seed.OpDescriptor{ .{ .kind = .Scan }, .{ .kind = .Expand }, .{ .kind = .Filter, .selectivity = 0.3 } };
    var ests = [_]f64{0} ** ops.len;
    var prev_cards: [1]seed.CardinalityEstimate = undefined;
    var prev_len: usize = 0;
    var i: usize = 0;
    while (i < ops.len) : (i += 1) {
        const slice = if (prev_len == 0) prev_cards[0..0] else prev_cards[0..1];
        const c = seed.estimate(ops[i], slice, cfg);
        ests[i] = c.rows;
        prev_cards[0] = c;
        prev_len = 1;
    }
    const actuals = [_]f64{ ests[0] * 1.5, ests[1] * 0.5, ests[2] * 1.2 };
    i = 0;
    while (i < ops.len) : (i += 1) reg.update(ops[i].kind, ests[i], actuals[i], cfg.adaptive_alpha);

    // Capture biases after updates
    const original_biases: [@typeInfo(seed.LogicalOpKind).Enum.fields.len]f64 = reg.biases;

    // Serialize to memory buffer
    var mem_buf: [512]u8 = undefined;
    var fbs = std.Io.fixedBufferStream(&mem_buf);
    try reg.serialize(fbs.writer());
    // bytes written = fbs.pos (unused, but serialization success implied by no error)

    // Zero out registry then deserialize
    reg.biases = [_]f64{1.0} ** @typeInfo(seed.LogicalOpKind).Enum.fields.len;
    fbs.seekTo(0) catch unreachable;
    try reg.deserialize(fbs.reader());

    // Verify biases restored (approx equality)
    for (original_biases, 0..) |ob, idx| {
        const rb = reg.biases[idx];
        // allow very small floating delta
        try std.testing.expect(std.math.fabs(ob - rb) < 1e-9);
    }
    // Basic JSON helper sanity
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const json = try reg.toJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(json.len > 2); // at least []
    try std.testing.expect(std.mem.indexOf(u8, json, ",") != null or @typeInfo(seed.LogicalOpKind).Enum.fields.len == 1);
}
