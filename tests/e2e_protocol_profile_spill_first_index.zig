const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn runProfile(allocator: std.mem.Allocator, query: []const u8) !std.json.Parsed(std.json.Value) {
    const port = util.getRandomPort() catch return error.PortUnavailable;
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    const env = &[_][]const u8{
        "GEODE_SPILL_THRESHOLD_BYTES=1",
    };

    var server = try util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr }, env);
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 10000);

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    const json = try client.executeProfileJson(allocator, query);
    defer allocator.free(json);

    return try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

fn findOpIndex(ops: []const std.json.Value, name: []const u8) ?usize {
    for (ops, 0..) |op_val, idx| {
        if (op_val != .object) continue;
        const op_name = op_val.object.get("op") orelse continue;
        if (op_name.* == .string and std.mem.eql(u8, op_name.string, name)) return idx;
    }
    return null;
}

test "profile: first_spill_op_index prefers Distinct over Sort" {
    const allocator = testing.allocator;
    var parsed = try runProfile(allocator, "PROFILE RETURN DISTINCT 1 AS x, 1 AS y ORDER BY x LIMIT 5");
    defer parsed.deinit();
    const profile = parsed.value;

    const ops_val = profile.object.get("ops") orelse return error.MissingOps;
    if (ops_val.* != .array) return error.BadOps;
    const ops = ops_val.array.items;
    const distinct_idx = findOpIndex(ops, "Distinct") orelse return error.MissingDistinct;
    const sort_idx = findOpIndex(ops, "Sort") orelse return error.MissingSort;
    try testing.expect(distinct_idx < sort_idx);

    const spills_val = profile.object.get("spills") orelse return error.MissingSpills;
    if (spills_val.* != .object) return error.BadSpills;
    const spills = spills_val.object;
    const reason = spills.get("spill_reason") orelse return error.MissingSpillReason;
    if (reason.* != .string) return error.BadSpillReason;
    try testing.expectEqualStrings("threshold", reason.string);
    const first_idx_val = spills.get("first_spill_op_index") orelse return error.MissingFirstSpillIndex;
    if (first_idx_val.* != .integer) return error.BadFirstSpillIndex;
    try testing.expectEqual(@as(usize, @intCast(first_idx_val.integer)), distinct_idx);
}

test "profile: first_spill_op_index is Sort when no Distinct" {
    const allocator = testing.allocator;
    var parsed = try runProfile(allocator, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 5");
    defer parsed.deinit();
    const profile = parsed.value;

    const ops_val = profile.object.get("ops") orelse return error.MissingOps;
    if (ops_val.* != .array) return error.BadOps;
    const ops = ops_val.array.items;
    const sort_idx = findOpIndex(ops, "Sort") orelse return error.MissingSort;

    const spills_val = profile.object.get("spills") orelse return error.MissingSpills;
    if (spills_val.* != .object) return error.BadSpills;
    const spills = spills_val.object;
    const reason = spills.get("spill_reason") orelse return error.MissingSpillReason;
    if (reason.* != .string) return error.BadSpillReason;
    try testing.expectEqualStrings("threshold", reason.string);
    const first_idx_val = spills.get("first_spill_op_index") orelse return error.MissingFirstSpillIndex;
    if (first_idx_val.* != .integer) return error.BadFirstSpillIndex;
    try testing.expectEqual(@as(usize, @intCast(first_idx_val.integer)), sort_idx);
}
