const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

// E2E: ensure committed_txns metric appears after a committed transaction in PROFILE totals.

test "protocol PROFILE committed_txns" {
    util.testStart("PROFILE committed_txns");
    errdefer util.testFail();

    const allocator = testing.allocator;

    var server = util.spawnServerRandom(allocator, util.TestEnv.standard()) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer server.deinit();

    util.progress("Connecting to {s}...", .{server.getAddr()});
    var client = try util.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();

    util.progress("Executing transaction...", .{});
    var begin_result = try client.begin(allocator);
    begin_result.deinit(allocator);
    try testing.expect(try client.commit(allocator));

    util.progress("Checking PROFILE for committed_txns metric...", .{});
    const json = try client.executeProfileJson(allocator, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1");
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value;
    const committed = root.object.get("committed_txns") orelse return error.MissingCommittedMetric;
    if (committed.integer < 1) return error.MissingCommittedMetric;

    util.testPass();
}
