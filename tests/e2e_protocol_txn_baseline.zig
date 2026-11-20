const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const TestContext = struct {
    server: util.ServerHandle,
    client: util.QuicProtoClient,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TestContext) void {
        self.client.deinit();
        self.server.deinit();
    }
};

fn startServerAndClient(allocator: std.mem.Allocator) !TestContext {
    var server = try util.spawnServerRandom(allocator, util.TestEnv.standard());
    errdefer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, server.getAddr());
    errdefer client.deinit();

    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    return .{ .server = server, .client = client, .allocator = allocator };
}

// Test baseline transaction functionality: BEGIN/COMMIT/ROLLBACK
test "e2e: transaction baseline BEGIN/COMMIT/ROLLBACK" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    util.testStart("transaction baseline BEGIN/COMMIT/ROLLBACK");
    errdefer util.testFail();

    const allocator = testing.allocator;
    var ctx = startServerAndClient(allocator) catch |err| {
        util.progress("Context setup failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer ctx.deinit();

    util.progress("Testing BEGIN...", .{});
    var begin_ok = try ctx.client.begin(allocator);
    defer begin_ok.deinit(allocator);
    try testing.expect(begin_ok.tx_id.len > 0);

    util.progress("Executing query in transaction...", .{});
    var exec = try ctx.client.executeAndCollect(allocator, "RETURN 1 AS x", util.emptyParams(), 100);
    defer exec.deinit(allocator);
    try testing.expect(exec.error_code == null);
    try testing.expect(exec.rows.len == 1);
    try testing.expect(exec.rows[0].len == 1);
    try testing.expect(exec.rows[0][0] == .int and exec.rows[0][0].int == 1);

    util.progress("Testing COMMIT...", .{});
    const commit_ok = try ctx.client.commit(allocator);
    try testing.expect(commit_ok);

    // SONNY-6548: this asserted that a BEGIN after the COMMIT is refused.
    // COMMIT ends the transaction (ISO/IEC 39075:2024 8.4 GR: the current
    // transaction is set to "not set"), so a new BEGIN starts one; only a
    // BEGIN inside an active transaction is refused (25G01, 4.10.4).
    util.progress("Testing BEGIN after COMMIT (starts a new transaction)...", .{});
    var begin_again = try ctx.client.begin(allocator);
    defer begin_again.deinit(allocator);
    try testing.expect(begin_again.tx_id.len > 0);

    util.progress("Testing nested BEGIN (should be rejected)...", .{});
    var begin_nested = try ctx.client.begin(allocator);
    defer begin_nested.deinit(allocator);
    try testing.expect(begin_nested.tx_id.len == 0);

    util.progress("Testing ROLLBACK of the open transaction...", .{});
    try testing.expect(try ctx.client.rollback(allocator));

    util.progress("Testing ROLLBACK with no active transaction...", .{});
    const rollback_ok = try ctx.client.rollback(allocator);
    try testing.expect(!rollback_ok);

    util.testPass();
}

// Test transaction rollback functionality
test "e2e: transaction rollback" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    util.testStart("transaction rollback");
    errdefer util.testFail();

    const allocator = testing.allocator;
    var ctx = startServerAndClient(allocator) catch |err| {
        util.progress("Context setup failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer ctx.deinit();

    util.progress("Beginning transaction...", .{});
    var begin_ok = try ctx.client.begin(allocator);
    defer begin_ok.deinit(allocator);
    try testing.expect(begin_ok.tx_id.len > 0);

    util.progress("Executing query...", .{});
    var res = try ctx.client.executeAndCollect(allocator, "RETURN 1 AS x", util.emptyParams(), 100);
    defer res.deinit(allocator);

    util.progress("Testing ROLLBACK...", .{});
    const rollback_ok = try ctx.client.rollback(allocator);
    try testing.expect(rollback_ok);

    util.progress("Testing COMMIT after ROLLBACK (should fail)...", .{});
    const commit_after = try ctx.client.commit(allocator);
    try testing.expect(!commit_after);

    util.testPass();
}

// Test transaction state management
test "e2e: transaction state management" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    util.testStart("transaction state management");
    errdefer util.testFail();

    const allocator = testing.allocator;
    var ctx = startServerAndClient(allocator) catch |err| {
        util.progress("Context setup failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer ctx.deinit();

    util.progress("Testing BEGIN/COMMIT cycle 1...", .{});
    var begin1 = try ctx.client.begin(allocator);
    begin1.deinit(allocator);
    try testing.expect(try ctx.client.commit(allocator));

    util.progress("Testing BEGIN/ROLLBACK cycle...", .{});
    var begin2 = try ctx.client.begin(allocator);
    begin2.deinit(allocator);
    try testing.expect(try ctx.client.rollback(allocator));

    util.progress("Testing BEGIN/COMMIT cycle 2...", .{});
    var begin3 = try ctx.client.begin(allocator);
    begin3.deinit(allocator);
    try testing.expect(try ctx.client.commit(allocator));

    util.testPass();
}
