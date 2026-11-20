const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

test "protocol txn basics" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    util.testStart("protocol txn basics");
    errdefer util.testFail();

    const allocator = testing.allocator;

    var server = util.spawnServerRandom(allocator, util.TestEnv.standard()) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        return err;
    };
    defer server.deinit();

    util.progress("Connecting to {s}...", .{server.getAddr()});
    var client = try util.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();

    util.progress("Authenticating...", .{});
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    util.progress("Testing BEGIN...", .{});
    var begin_ok = try client.begin(allocator);
    defer begin_ok.deinit(allocator);
    try testing.expect(begin_ok.tx_id.len > 0);

    util.progress("Testing nested BEGIN (should return empty tx_id)...", .{});
    var begin_nested = try client.begin(allocator);
    defer begin_nested.deinit(allocator);
    try testing.expect(begin_nested.tx_id.len == 0);

    util.progress("Testing COMMIT...", .{});
    try testing.expect(try client.commit(allocator));

    util.progress("Testing ROLLBACK with no active transaction...", .{});
    try testing.expect(!try client.rollback(allocator));

    util.testPass();
}
