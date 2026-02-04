const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

// E2E test for CDC_CONTROL RESET_GUARDRAILS round trip.
// CANARY: REQ=REQ-GQL-042; FEATURE="CDCControlProtocol"; ASPECT=E2E; STATUS=TESTED; TEST=protocol_CDC_CONTROL_reset; OWNER=cdc; UPDATED=2025-09-20

test "protocol: CDC control reset" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:8571";

    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr },
        &.{ "GEODE_CDC_ENABLE=1" },
    );
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();

    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer hello.deinit(allocator);

    var diag1 = try client.cdcDiagnostics(allocator);
    defer diag1.deinit(allocator);
    const epoch1 = diag1.guardrail_epoch;

    var ctrl = try client.cdcControl(allocator, "RESET_GUARDRAILS");
    defer ctrl.deinit(allocator);
    try testing.expect(ctrl.success);
    try testing.expect(std.mem.eql(u8, ctrl.status, "OK"));

    var diag2 = try client.cdcDiagnostics(allocator);
    defer diag2.deinit(allocator);
    const epoch2 = diag2.guardrail_epoch;

    try testing.expect(epoch2 == epoch1 + 1);
}
