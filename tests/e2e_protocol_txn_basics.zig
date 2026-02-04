const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

test "protocol txn basics" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:17683";

    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr }, null);
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    const begin_ok = try client.begin(allocator);
    defer begin_ok.deinit(allocator);
    try testing.expect(begin_ok.tx_id.len > 0);

    const begin_nested = try client.begin(allocator);
    defer begin_nested.deinit(allocator);
    try testing.expect(begin_nested.tx_id.len == 0);

    try testing.expect(try client.commit(allocator));
    try testing.expect(!try client.rollback(allocator));
}
