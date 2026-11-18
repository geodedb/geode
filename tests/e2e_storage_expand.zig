const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const schema = @import("schema");

fn expectInt(val: util.TestValue, expected: i64) !void {
    switch (val) {
        .int => |v| try testing.expectEqual(expected, v),
        else => return error.UnexpectedValueType,
    }
}

fn execOk(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !void {
    var params = std.ArrayList(schema.Param).init(allocator);
    defer params.deinit(allocator);
    var res = try client.executeAndCollect(allocator, query, params, 1000);
    defer res.deinit(allocator);
    try testing.expectEqualStrings("00000", res.status_class);
}

fn seedTiny(client: *util.QuicProtoClient, allocator: std.mem.Allocator) !void {
    const seed = [_][]const u8{
        "CREATE (:Node {id: 0})",
        "CREATE (:Node {id: 1})",
        "CREATE (:Node {id: 2})",
        "MATCH (a:Node {id: 0}), (b:Node {id: 1}) CREATE (a)-[:LINK]->(b)",
        "MATCH (a:Node {id: 0}), (b:Node {id: 2}) CREATE (a)-[:LINK]->(b)",
    };
    for (seed) |q| try execOk(client, allocator, q);
}

test "storage: 1-hop expansion (GraphStore)" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    util.testStart("1-hop expansion (GraphStore)");
    errdefer util.testFail();

    const allocator = testing.allocator;

    util.progress("Creating temp directory...", .{});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d}...", .{port});
    var server = util.spawnServer(
        allocator,
        &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data_dir", tmp.dir_path },
        util.TestEnv.standard(),
    ) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer server.deinit();

    // Wait for server readiness
    util.waitForServerReady(allocator, addr, 10000) catch |err| {
        util.progress("Server readiness timeout: {}", .{err});
        util.testSkip();
        return;
    };

    util.progress("Connecting to server...", .{});
    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();

    util.progress("Authenticating...", .{});
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer hello.deinit(allocator);

    util.progress("Seeding graph data...", .{});
    try seedTiny(&client, allocator);

    util.progress("Executing 1-hop expansion query...", .{});
    var params = std.ArrayList(schema.Param).init(allocator);
    defer params.deinit(allocator);
    var res = try client.executeAndCollect(allocator, "MATCH (a:Node {id: 0})-[:LINK]->(b) RETURN b.id AS n ORDER BY n", params, 1000);
    defer res.deinit(allocator);

    try testing.expect(res.ordered);
    try testing.expectEqual(@as(usize, 1), res.order_keys.len);
    try testing.expectEqualStrings("n", res.order_keys[0]);
    try testing.expectEqual(@as(usize, 2), res.rows.len);
    try expectInt(res.rows[0][0], 1);
    try expectInt(res.rows[1][0], 2);

    util.testPass();
}
