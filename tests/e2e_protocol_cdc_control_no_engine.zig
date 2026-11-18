const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDCControlProtocol"; ASPECT=E2ENoEngine; STATUS=TESTED; TEST=protocol_CDC_CONTROL_no_engine; OWNER=cdc; UPDATED=2025-09-20

test "protocol: CDC control when engine disabled" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    util.testStart("CDC control when engine disabled");
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
    defer hello.deinit(allocator);

    util.progress("Sending RESET_GUARDRAILS to server without CDC...", .{});
    var ctrl = try client.cdcControl(allocator, "RESET_GUARDRAILS");
    defer ctrl.deinit(allocator);

    try testing.expect(!ctrl.success);
    try testing.expect(std.mem.eql(u8, ctrl.status, "NO_ENGINE"));

    util.testPass();
}
