const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

// Transactions lifecycle: BEGIN -> nested BEGIN error -> RUN query -> COMMIT -> ROLLBACK error
test "transactions e2e basic lifecycle" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:17684";

    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--disable-auth" }, null);
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, "", "");
    hello.deinit(allocator);

    const begin_ok = try client.begin(allocator);
    defer begin_ok.deinit(allocator);
    try testing.expect(begin_ok.tx_id.len > 0);

    const begin_nested = try client.begin(allocator);
    defer begin_nested.deinit(allocator);
    try testing.expect(begin_nested.tx_id.len == 0);

    const exec = try client.executeAndCollect(allocator, "RETURN 1 AS x ORDER BY x LIMIT 1", util.emptyParams(), 100);
    defer exec.deinit(allocator);
    try testing.expect(exec.error_code == null);
    try testing.expect(exec.rows.len == 1);
    try testing.expect(exec.rows[0].len == 1);
    try testing.expect(exec.rows[0][0] == .int and exec.rows[0][0].int == 1);

    try testing.expect(try client.commit(allocator));
    try testing.expect(!try client.rollback(allocator));
}
