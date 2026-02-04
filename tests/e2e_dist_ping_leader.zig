const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

test "PING ok in single-node raft mode" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:17686";

    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen-quic", addr, "--dist-enable-raft", "--disable-auth" }, null);
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, "", "");
    hello.deinit(allocator);

    try testing.expect(try client.ping(allocator));
}
