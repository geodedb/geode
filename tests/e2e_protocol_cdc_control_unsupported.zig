const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDCControlProtocol"; ASPECT=E2EUnsupported; STATUS=TESTED; TEST=protocol_CDC_CONTROL_unsupported; OWNER=cdc; UPDATED=2025-09-20

test "protocol: CDC control unsupported action" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:8578";

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

    var ctrl = try client.cdcControl(allocator, "UNKNOWN_ACTION");
    defer ctrl.deinit(allocator);

    try testing.expect(!ctrl.success);
    try testing.expect(std.mem.eql(u8, ctrl.status, "UNSUPPORTED"));
}
