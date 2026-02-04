const std = @import("std");
const schema = @import("schema");
const profile_payload = @import("server/profile_payload.zig");

// Unit test: profile payload JSON includes flagger findings in order.

test "profile payload JSON includes flags in order" {
    const allocator = std.testing.allocator;
    const flags = [_][]const u8{ "I:IllegalOrderKeyPolicy=ident-only", "U:NullsFirstPolicy" };

    var op_list = std.ArrayList(schema.ProfileOp).initCapacity(allocator, 0) catch return error.OutOfMemory;
    var peak = std.ArrayList(schema.ProfilePeakContributor).initCapacity(allocator, 0) catch return error.OutOfMemory;
    var mem_curve = std.ArrayList(schema.ProfileMemCurvePoint).initCapacity(allocator, 0) catch return error.OutOfMemory;
    var findings = std.ArrayList([]const u8).initCapacity(allocator, flags.len) catch return error.OutOfMemory;
    for (flags) |flag| {
        try findings.append(allocator, try allocator.dupe(u8, flag));
    }

    var payload = schema.ProfilePayload{
        .profile_version = 1,
        .ops = op_list,
        .peak_contributors = peak,
        .totals = schema.ProfileTotals{ .time_ns = 0, .peak_bytes = 0 },
        .total_time_ns = 0,
        .spills = null,
        .memory = null,
        .planner_estimates = null,
        .mem_curve = mem_curve,
        .setop = null,
        .hashagg_spills = 0,
        .hashagg_spill_reason = "",
        .committed_txns = 0,
        .graph_store_nodes = 0,
        .graph_store_edges = 0,
        .graph_store_dirty = false,
        .flagger_findings = findings,
        .compact = false,
    };
    defer payload.deinit(allocator);

    const json = try profile_payload.profilePayloadToJson(allocator, payload);
    defer allocator.free(json);

    const pos_illegal = std.mem.indexOf(u8, json, flags[0]) orelse return error.FlagMissing;
    const pos_nulls = std.mem.indexOf(u8, json, flags[1]) orelse return error.FlagMissing2;
    try std.testing.expect(pos_illegal < pos_nulls);
}
