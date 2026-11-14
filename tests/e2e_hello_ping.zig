const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

test "HELLO returns capabilities and PING returns ok" {
    util.testStart("HELLO returns capabilities and PING returns ok");
    errdefer util.testFail();

    const allocator = testing.allocator;

    // Use random port to avoid conflicts
    var server = util.spawnServerRandom(allocator, util.TestEnv.standard()) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        return err;
    };
    defer server.deinit();

    util.progress("Connecting to {s}...", .{server.getAddr()});
    var client = try util.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();

    util.progress("Sending HELLO...", .{});
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
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

    util.progress("Sending PING...", .{});
    try testing.expect(try client.ping(allocator));

    util.testPass();
}
