const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

// E2E: ensure spill_reason appears when memory threshold exceeded

test "protocol PROFILE sort_spill" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:17687";

    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr },
        &.{ "GEODE_SPILL_THRESHOLD_BYTES=1" },
    );
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();

    const json = try client.executeProfileJson(allocator, "PROFILE RETURN 1 AS x ORDER BY x");
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value;
    const spills = root.object.get("spills") orelse return error.MissingSpills;
    const reason = spills.object.get("spill_reason") orelse return error.MissingSpillReason;
    try testing.expectEqualStrings("threshold", reason.string);
}
