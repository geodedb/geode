const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const proto = @import("proto_test_util.zig");
const schema = @import("schema");

fn runQuery(allocator: std.mem.Allocator, addr: []const u8, query: []const u8) !proto.ExecResult {
    var client = try proto.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    const hello = try client.hello(allocator, proto.defaultUsername(), proto.defaultPassword());
    defer hello.deinit(allocator);

    const params = std.ArrayList(schema.Param).init(allocator);
    return client.executeAndCollect(allocator, query, params, 0);
}

test "ORDER policy: expr forbidden by default" {
    proto.testStart("ORDER policy: expr forbidden by default");
    errdefer proto.testFail();

    const allocator = testing.allocator;

    // Get random port
    const port = proto.getRandomPort() catch |err| {
        proto.progress("Port allocation failed: {}", .{err});
        proto.testSkip();
        return;
    };
    const addr = try proto.formatAddr(allocator, port);
    defer allocator.free(addr);

    proto.progress("Starting server on port {d}...", .{port});

    var server = try proto.spawnServer(
        allocator,
        &.{ geode_test_bin.geode_exe, "serve", "--listen", addr },
        proto.TestEnv.standard(),
    );
    defer server.deinit();

    proto.waitForServerReady(allocator, addr, 10000) catch |err| {
        proto.progress("Server readiness timeout: {}", .{err});
        proto.testSkip();
        return;
    };

    proto.progress("Running query...", .{});
    var res = try runQuery(allocator, addr, "RETURN a ORDER BY f(a)");
    defer res.deinit(allocator);

    try testing.expect(res.error_code != null);
    if (res.error_message) |msg| {
        try testing.expect(std.mem.indexOf(u8, msg, "ORDER BY") != null or std.mem.indexOf(u8, msg, "IllegalOrderKey") != null);
    }

    proto.testPass();
}

test "ORDER policy: expr allowed with --order-keys expr" {
    proto.testStart("ORDER policy: expr allowed with --order-keys expr");
    errdefer proto.testFail();

    const allocator = testing.allocator;

    // Get random port
    const port = proto.getRandomPort() catch |err| {
        proto.progress("Port allocation failed: {}", .{err});
        proto.testSkip();
        return;
    };
    const addr = try proto.formatAddr(allocator, port);
    defer allocator.free(addr);

    proto.progress("Starting server on port {d} with --order-keys expr...", .{port});

    var server = try proto.spawnServer(
        allocator,
        &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--order-keys", "expr" },
        proto.TestEnv.standard(),
    );
    defer server.deinit();

    proto.waitForServerReady(allocator, addr, 10000) catch |err| {
        proto.progress("Server readiness timeout: {}", .{err});
        proto.testSkip();
        return;
    };

    proto.progress("Running query...", .{});
    var res = try runQuery(allocator, addr, "RETURN a ORDER BY f(a)");
    defer res.deinit(allocator);

    try testing.expect(res.error_code == null);
    try testing.expect(res.columns.len > 0);

    proto.testPass();
}
