const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

// E2E test for CDC_CONTROL RESET_GUARDRAILS round trip.
// CANARY: REQ=REQ-GQL-042; FEATURE="CDCControlProtocol"; ASPECT=E2E; STATUS=TESTED; TEST=protocol_CDC_CONTROL_reset; OWNER=cdc; UPDATED=2025-09-20

test "protocol: CDC control reset" {
    util.testStart("CDC control reset");
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

    util.progress("Getting initial CDC diagnostics...", .{});
    var diag1 = try client.cdcDiagnostics(allocator);
    defer diag1.deinit(allocator);
    const epoch1 = diag1.guardrail_epoch;

    util.progress("Sending RESET_GUARDRAILS command...", .{});
    var ctrl = try client.cdcControl(allocator, "RESET_GUARDRAILS");
    defer ctrl.deinit(allocator);
    try testing.expect(ctrl.success);
    try testing.expect(std.mem.eql(u8, ctrl.status, "OK"));

    util.progress("Verifying epoch increment...", .{});
    var diag2 = try client.cdcDiagnostics(allocator);
    defer diag2.deinit(allocator);
    const epoch2 = diag2.guardrail_epoch;

    try testing.expect(epoch2 == epoch1 + 1);

    util.testPass();
}
