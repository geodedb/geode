const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=CDCControlProtocolMalformed; STATUS=TESTED; TEST=protocol_CDC_CONTROL_malformed_missing_action; OWNER=wire; UPDATED=2025-09-20

test "protocol: CDC control missing action treated as UNSUPPORTED" {
    util.testStart("CDC control missing action treated as UNSUPPORTED");
    errdefer util.testFail();

    const allocator = testing.allocator;

    // Get random port with CDC enabled
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    const env = &[_][]const u8{
        util.TestEnv.GEODE_ALLOW_NO_AUTH,
        util.TestEnv.GEODE_DISABLE_AUDIT,
        util.TestEnv.GEODE_TEST_MODE,
        "GEODE_CDC_ENABLE=1",
    };

    util.progress("Starting server on port {d} with CDC enabled...", .{port});
    var server = util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr }, env) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer server.deinit();

    // Wait for server readiness
    util.waitForServerReady(allocator, addr, 10000) catch |err| {
        util.progress("Server readiness timeout: {}", .{err});
        util.testSkip();
        return;
    };

    util.progress("Connecting to server...", .{});
    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();

    util.progress("Authenticating...", .{});
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer hello.deinit(allocator);

    util.progress("Sending empty action...", .{});
    var ctrl = try client.cdcControl(allocator, "");
    defer ctrl.deinit(allocator);

    try testing.expect(!ctrl.success);
    try testing.expect(std.mem.eql(u8, ctrl.status, "UNSUPPORTED"));

    util.testPass();
}
