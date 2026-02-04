const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

// Transactions lifecycle: BEGIN -> nested BEGIN error -> RUN query -> COMMIT -> ROLLBACK error
test "transactions e2e basic lifecycle" {
    util.testStart("transactions e2e basic lifecycle");
    errdefer util.testFail();

    const allocator = testing.allocator;

    var server = util.spawnServerRandom(allocator, util.TestEnv.standard()) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer server.deinit();

    util.progress("Connecting to {s}...", .{server.getAddr()});
    var client = try util.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();

    util.progress("Authenticating...", .{});
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    util.progress("Testing BEGIN transaction...", .{});
    var begin_ok = try client.begin(allocator);
    defer begin_ok.deinit(allocator);
    try testing.expect(begin_ok.tx_id.len > 0);

    util.progress("Testing nested BEGIN (should return empty tx_id)...", .{});
    var begin_nested = try client.begin(allocator);
    defer begin_nested.deinit(allocator);
    try testing.expect(begin_nested.tx_id.len == 0);

    util.progress("Executing query in transaction...", .{});
    var exec = try client.executeAndCollect(allocator, "RETURN 1 AS x ORDER BY x LIMIT 1", util.emptyParams(), 100);
    defer exec.deinit(allocator);
    try testing.expect(exec.error_code == null);
    try testing.expect(exec.rows.len == 1);
    try testing.expect(exec.rows[0].len == 1);
    try testing.expect(exec.rows[0][0] == .int and exec.rows[0][0].int == 1);

    util.progress("Testing COMMIT...", .{});
    try testing.expect(try client.commit(allocator));

    util.progress("Testing ROLLBACK (should fail - no active transaction)...", .{});
    try testing.expect(!try client.rollback(allocator));

    util.testPass();
}
