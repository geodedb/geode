const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn startServerAndClient(allocator: std.mem.Allocator, port: u16) !struct {
    server: util.ServerHandle,
    client: util.QuicProtoClient,
} {
    const addr = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{port});
    defer allocator.free(addr);

    const server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--disable-auth" }, null);
    var client = try util.QuicProtoClient.connect(allocator, addr);
    var hello = try client.hello(allocator, "", "");
    hello.deinit(allocator);

    return .{ .server = server, .client = client };
}

// Test baseline transaction functionality: BEGIN/COMMIT/ROLLBACK
test "e2e: transaction baseline BEGIN/COMMIT/ROLLBACK" {
    const allocator = testing.allocator;
    var ctx = try startServerAndClient(allocator, 17680);
    defer ctx.client.deinit();
    defer ctx.server.deinit();

    const begin_ok = try ctx.client.begin(allocator);
    defer begin_ok.deinit(allocator);
    try testing.expect(begin_ok.tx_id.len > 0);

    const exec = try ctx.client.executeAndCollect(allocator, "RETURN 1 AS x", util.emptyParams(), 100);
    defer exec.deinit(allocator);
    try testing.expect(exec.error_code == null);
    try testing.expect(exec.rows.len == 1);
    try testing.expect(exec.rows[0].len == 1);
    try testing.expect(exec.rows[0][0] == .int and exec.rows[0][0].int == 1);

    const commit_ok = try ctx.client.commit(allocator);
    try testing.expect(commit_ok);

    // Nested BEGIN should be rejected (empty tx_id)
    const begin_again = try ctx.client.begin(allocator);
    defer begin_again.deinit(allocator);
    try testing.expect(begin_again.tx_id.len == 0);

    const rollback_ok = try ctx.client.rollback(allocator);
    try testing.expect(!rollback_ok);
}

// Test transaction rollback functionality
test "e2e: transaction rollback" {
    const allocator = testing.allocator;
    var ctx = try startServerAndClient(allocator, 17681);
    defer ctx.client.deinit();
    defer ctx.server.deinit();

    const begin_ok = try ctx.client.begin(allocator);
    defer begin_ok.deinit(allocator);
    try testing.expect(begin_ok.tx_id.len > 0);

    _ = try ctx.client.executeAndCollect(allocator, "RETURN 1 AS x", util.emptyParams(), 100);

    const rollback_ok = try ctx.client.rollback(allocator);
    try testing.expect(rollback_ok);

    const commit_after = try ctx.client.commit(allocator);
    try testing.expect(!commit_after);
}

// Test transaction state management
test "e2e: transaction state management" {
    const allocator = testing.allocator;
    var ctx = try startServerAndClient(allocator, 17682);
    defer ctx.client.deinit();
    defer ctx.server.deinit();

    var begin1 = try ctx.client.begin(allocator);
    begin1.deinit(allocator);
    try testing.expect(try ctx.client.commit(allocator));

    var begin2 = try ctx.client.begin(allocator);
    begin2.deinit(allocator);
    try testing.expect(try ctx.client.rollback(allocator));

    var begin3 = try ctx.client.begin(allocator);
    begin3.deinit(allocator);
    try testing.expect(try ctx.client.commit(allocator));
}
