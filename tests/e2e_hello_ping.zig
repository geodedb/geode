const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

test "HELLO returns capabilities and PING returns ok" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:17685";

    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--disable-auth" }, null);
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();

    var hello = try client.hello(allocator, "", "");
    defer hello.deinit(allocator);
    try testing.expect(hello.success);
    try testing.expect(hello.capabilities.len > 0);

    var saw_proto = false;
    for (hello.capabilities) |cap| {
        if (std.mem.eql(u8, cap, "PROTOBUF")) {
            saw_proto = true;
            break;
        }
    }
    try testing.expect(saw_proto);

    try testing.expect(try client.ping(allocator));
}
