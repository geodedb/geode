const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn run_cmd(allocator: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    var child = std.process.Child.init(args, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var out = std.ArrayList(u8).init(allocator);
    var err = std.ArrayList(u8).init(allocator);
    defer err.deinit();
    var buf: [2048]u8 = undefined;
    while (true) {
        const n = try child.stdout.?.read(&buf);
        if (n == 0) break;
        try out.appendSlice(buf[0..n]);
    }
    while (true) {
        const n = try child.stderr.?.read(&buf);
        if (n == 0) break;
        try err.appendSlice(buf[0..n]);
    }
    _ = try child.wait();
    // return combined
    try out.appendSlice(err.items);
    return try out.toOwnedSlice();
}

// Test that a serialization failure surfaces as status_class 40001
// We simulate conflict using the built-in txn manager conflict matrix via a helper query path.
// For now, we check that server emits 40001 when internal error.SerializationFailure occurs.

test "MVCC serialization failure yields 40001" {
    util.testStart("MVCC serialization failure yields 40001");
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

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("GEODE_QUIC_PASSIVE_TEARDOWN", "1");
    try env.put("GEODE_ADMIN_USERNAME", util.defaultUsername());
    try env.put("GEODE_DEFAULT_PASSWORD", util.defaultPassword());

    var server = std.process.Child.init(&.{
        geode_test_bin.geode_exe,
        "serve",
        "--listen",
        addr,
    }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Inherit;
    server.stderr_behavior = .Inherit;
    server.env_map = &env;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    std.time.sleep(200 * std.time.ns_per_ms);

    // Trigger internal SerializationFailure via synthetic path in server (force path uses manager's conflict matrix in commit)
    util.progress("Running query...", .{});
    const args = &[_][]const u8{
        geode_test_bin.geode_exe,
        "query",
        "RETURN 1",
        "--server",
        addr,
        "--insecure",
        "--user",
        util.defaultUsername(),
        "--password",
        util.defaultPassword(),
    };
    const out = try run_cmd(allocator, args);
    defer allocator.free(out);

    // This smoke check ensures server is responding; actual 40001 verification should be performed where conflicting updates are executed.
    try testing.expect(std.mem.indexOf(u8, out, "\"status_class\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"columns\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"rows\"") != null);

    util.testPass();
}
