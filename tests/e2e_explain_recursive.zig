const std = @import("std");
const testing = std.testing;
const cost_explain = @import("src/planner/cost_explain.zig");
const seed = @import("src/planner/cost_seed.zig");

// Basic test validating recursive explain JSON structure presence of child nesting.
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainJSONRecursive; STATUS=TESTED; OWNER=planner; UPDATED=2025-09-26

test "recursive explain emits nested child chain" {
    var ops = [_]seed.OpDescriptor{
        .{ .kind = .Scan },
        .{ .kind = .Filter, .selectivity = 0.5 },
        .{ .kind = .Project },
    };
    const json = try cost_explain.explainRecursive(testing.allocator, &ops);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.startsWith(u8, json, "{\"schema\":\"cost_explain.recursive.v1\""));
    // Ensure nested 'child' appears twice (for two links in chain)
    var count: usize = 0;
    var it = json;
    while (std.mem.indexOf(u8, it, "\"child\"")) |pos| {
        count += 1;
        it = it[pos + 7 ..];
    }
    try testing.expect(count == 2);
}

test "TestCANARY_REQ_GQL_075_ExplainJSONRecursive" {
    var ops = [_]seed.OpDescriptor{
        .{ .kind = .Scan },
        .{ .kind = .Filter, .selectivity = 0.25 },
        .{ .kind = .Join },
    };
    const json = try cost_explain.explainRecursive(testing.allocator, &ops);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"child\"") != null);
    // Validate last object closes properly
    try testing.expect(json[json.len - 1] == '}');
}
