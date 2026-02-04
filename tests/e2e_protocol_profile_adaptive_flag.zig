const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn runQuery(allocator: std.mem.Allocator, addr: []const u8, query: []const u8) ![]u8 {
    var child = std.process.Child.init(
        &.{
            "./zig-out/bin/geode",
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
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 16);
    _ = try child.stderr.?.readToEndAlloc(allocator, 1 << 12);
    _ = try child.wait();
    return out;
}

test "protocol: PROFILE adaptive estimates flag when env enabled" {
    util.testStart("PROFILE adaptive estimates flag");
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

    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr },
        &.{"GEODE_ADAPT_ESTIMATES=1"},
    );
    defer server.deinit();

    util.waitForServerReady(allocator, addr, 10000) catch |err| {
        util.progress("Server readiness timeout: {}", .{err});
        util.testSkip();
        return;
    };

    util.progress("Running PROFILE query...", .{});
    const out = try runQuery(allocator, addr, "PROFILE RETURN 1 AS x LIMIT 1");
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "U:AdaptiveEstimatesPlanned") != null);

    util.testPass();
}
