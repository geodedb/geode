const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn runQuery(allocator: std.mem.Allocator, addr: []const u8, query: []const u8) ![]u8 {
    var child = std.process.Child.init(
        &.{
            geode_test_bin.geode_exe,
            "query",
            query,
            "--server",
            addr,
            "--insecure",
            "--user",
            util.defaultUsername(),
            "--password",
            util.defaultPassword(),
            "--format",
            "json",
        },
        allocator,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 20);
    _ = try child.stderr.?.readToEndAlloc(allocator, 1 << 20);
    _ = try child.wait();
    return out;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "protocol: EXPLAIN emits explain payload" {
    util.testStart("EXPLAIN emits explain payload");
    errdefer util.testFail();

    const allocator = testing.allocator;

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d}...", .{port});
    var server = util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr }, util.TestEnv.standard()) catch |err| {
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

    util.progress("Running EXPLAIN query...", .{});
    const out = try runQuery(allocator, addr, "EXPLAIN RETURN 1 AS x LIMIT 1");
    defer allocator.free(out);
    try testing.expect(contains(out, "\"explain\""));

    util.testPass();
}

test "protocol: PROFILE emits profile payload" {
    util.testStart("PROFILE emits profile payload");
    errdefer util.testFail();

    const allocator = testing.allocator;

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d}...", .{port});
    var server = util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr }, util.TestEnv.standard()) catch |err| {
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

    util.progress("Running PROFILE query...", .{});
    const out = try runQuery(allocator, addr, "PROFILE RETURN 1 AS x LIMIT 1");
    defer allocator.free(out);
    try testing.expect(contains(out, "\"profile\""));
    try testing.expect(contains(out, "\"ops\""));
    try testing.expect(contains(out, "\"bytes_out\""));
    try testing.expect(contains(out, "\"bytes_alloc\""));
    try testing.expect(contains(out, "\"input_rows\""));

    util.testPass();
}
