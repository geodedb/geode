const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn runProfileWithThreshold(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    const port = util.getRandomPort() catch return error.PortUnavailable;
    const addr = try util.formatAddr(allocator, port);
    errdefer allocator.free(addr);

    const env = &[_][]const u8{
        "GEODE_SPILL_THRESHOLD_BYTES=1",
    };

    var server = try util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr }, env);
    errdefer server.deinit();
    try util.waitForServerReady(allocator, addr, 10000);

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    const json = try client.executeProfileJson(allocator, query);
    server.deinit();
    allocator.free(addr);
    return json;
}

fn getSpillCount(spills: std.json.Value, key: []const u8) !u64 {
    const val = spills.object.get(key) orelse return error.MissingSpillKey;
    return switch (val) {
        .integer => |i| @intCast(i),
        .float => |f| @intCast(@as(i64, @intFromFloat(f))),
        else => return error.InvalidSpillValue,
    };
}

test "profile spills threshold for ordered query" {
    const allocator = testing.allocator;
    const json = try runProfileWithThreshold(allocator, "PROFILE RETURN 1 AS x ORDER BY x");
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const spills = parsed.value.object.get("spills") orelse return error.MissingSpills;
    const reason = spills.object.get("spill_reason") orelse return error.MissingSpillReason;
    try testing.expectEqualStrings("threshold", reason.string);
    try testing.expectEqual(@as(u64, 1), try getSpillCount(spills, "sort_spills"));
    try testing.expectEqual(@as(u64, 0), try getSpillCount(spills, "distinct_spills"));
    try testing.expectEqual(@as(u64, 0), try getSpillCount(spills, "union_spills"));
}

test "profile spills threshold for union distinct query" {
    const allocator = testing.allocator;
    const json = try runProfileWithThreshold(allocator, "PROFILE RETURN 1 AS x UNION RETURN 1 AS x");
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const spills = parsed.value.object.get("spills") orelse return error.MissingSpills;
    const reason = spills.object.get("spill_reason") orelse return error.MissingSpillReason;
    try testing.expectEqualStrings("threshold", reason.string);
    try testing.expectEqual(@as(u64, 0), try getSpillCount(spills, "sort_spills"));
    try testing.expectEqual(@as(u64, 1), try getSpillCount(spills, "distinct_spills"));
    try testing.expectEqual(@as(u64, 1), try getSpillCount(spills, "union_spills"));
}
