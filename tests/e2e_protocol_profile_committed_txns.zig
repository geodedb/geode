const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

// E2E: ensure committed_txns metric appears after a committed transaction in PROFILE totals.

test "protocol PROFILE committed_txns" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:17686";

    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr }, null);
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();

    _ = try client.begin(allocator);
    try testing.expect(try client.commit(allocator));

    const json = try client.executeProfileJson(allocator, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1");
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value;
    const committed = root.object.get("committed_txns") orelse return error.MissingCommittedMetric;
    if (committed.integer < 1) return error.MissingCommittedMetric;
}
