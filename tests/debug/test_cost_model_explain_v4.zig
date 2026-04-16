const std = @import("std");
const seed = @import("src/planner/cost_seed.zig");
const explain = @import("src/planner/cost_explain.zig");

// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainJSONDynamicAlpha; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_ExplainJSONDynamicAlpha; OWNER=planner; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_075_ExplainJSONDynamicAlpha" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const allocator = gpa.allocator();

    var reg: seed.AdaptiveBiasRegistry = .{};
    // Simulate a sequence of updates to produce varying CV classes
    var i: usize = 0;
    while (i < 25) : (i += 1) {
        // Alternate stable and volatile patterns for Scan and Expand
        reg.updateAdaptive(.Scan, 1000, if (i % 2 == 0) 1005 else 950);
        reg.updateAdaptive(.Expand, 800, if (i % 5 == 0) 400 else 1400);
    }

    // Build a tiny operator chain using kinds we updated.
    const ops = [_]seed.OpDescriptor{
        .{ .kind = .Scan },
        .{ .kind = .Expand },
        .{ .kind = .Filter, .selectivity = 0.5 },
    };

    const json_bytes = try explain.explainChainUnifiedV4(allocator, &ops, &reg);
    defer allocator.free(json_bytes);

    const json = json_bytes;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema\":\"cost_explain.v4\"") != null);
    // Check presence of alpha and cv keys
    try std.testing.expect(std.mem.indexOf(u8, json, "\"alpha\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cv\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cv_class\":") != null);
    // Snapshot arrays
    try std.testing.expect(std.mem.indexOf(u8, json, "\"alpha_snapshot\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cv_snapshot\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cv_class_snapshot\":[") != null);
}
