const std = @import("std");
const seed = @import("../src/planner/cost_seed.zig");
const explain = @import("../src/planner/cost_explain.zig");

// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainJSONDetailed; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_CostModelExplainJSONDetailed; OWNER=planner; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_075_CostModelExplainJSONDetailed" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const ops = [_]seed.OpDescriptor{
        .{ .kind = .Scan },
        .{ .kind = .Expand },
        .{ .kind = .Filter, .selectivity = 0.4 },
        .{ .kind = .Project },
        .{ .kind = .Limit },
    };
    const json = try explain.explainChain(gpa.allocator(), &ops);
    defer gpa.allocator().free(json);
    // Structural expectations for detailed explain:
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema\":\"cost_explain.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ops\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"est_rows\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cost\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"totals\":{") != null);
    // Ensure deprecated field from earlier version (row_estimate_final) is absent.
    try std.testing.expect(std.mem.indexOf(u8, json, "row_estimate_final") == null);
    // Order sanity: Scan appears before Expand, Expand before Filter, etc.
    const pos_scan = std.mem.indexOf(u8, json, "\"kind\":\"Scan\"") orelse return error.ScanMissing;
    const pos_expand = std.mem.indexOf(u8, json, "\"kind\":\"Expand\"") orelse return error.ExpandMissing;
    const pos_filter = std.mem.indexOf(u8, json, "\"kind\":\"Filter\"") orelse return error.FilterMissing;
    const pos_project = std.mem.indexOf(u8, json, "\"kind\":\"Project\"") orelse return error.ProjectMissing;
    const pos_limit = std.mem.indexOf(u8, json, "\"kind\":\"Limit\"") orelse return error.LimitMissing;
    try std.testing.expect(pos_scan < pos_expand and pos_expand < pos_filter and pos_filter < pos_project and pos_project < pos_limit);
    // Totals numeric fields present (primitive heuristic check):
    try std.testing.expect(std.mem.indexOf(u8, json, "\"totals\":{\"est_rows\":") != null);
}
