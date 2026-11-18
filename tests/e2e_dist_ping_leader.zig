const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

test "PING ok in single-node raft mode" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    util.testStart("PING ok in single-node raft mode");
    errdefer util.testFail();

    const allocator = testing.allocator;

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        return err;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d} with Raft enabled...", .{port});
    var server = util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr }, util.TestEnv.standard()) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        return err;
    };
    defer server.deinit();

    // Wait for server readiness
    util.waitForServerReady(allocator, addr, 10000) catch |err| {
        util.progress("Server readiness timeout: {}", .{err});
        return err;
    };

    util.progress("Connecting to server...", .{});
    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();

    util.progress("Authenticating...", .{});
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    util.progress("Sending PING...", .{});
    try testing.expect(try client.ping(allocator));

    util.testPass();
}
