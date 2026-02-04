const std = @import("std");
const util = @import("proto_test_util.zig");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run(allocator: std.mem.Allocator, args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit(allocator);
    try argv.append(allocator, args[0]);
    if (args.len > 1 and !std.mem.eql(u8, args[1], "query")) {
        try argv.append(allocator, "query");
    }
    try argv.appendSlice(allocator, args[1..]);
    var child = Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 20);
    const err = try child.stderr.?.readToEndAlloc(allocator, 1 << 20);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = out, .err = err };
}

test "quic: EXPLAIN schema then explain (smoke)" {
    util.testStart("EXPLAIN schema then explain (smoke)");
    errdefer util.testFail();

    const allocator = std.testing.allocator;
    const geode = "./zig-out/bin/geode";

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d}...", .{port});

    // Start server in background with QUIC, exit after first request
    var srv = Child.init(&.{ geode, "serve", "--listen", addr, "--log-level", "info" }, allocator);
    srv.stdin_behavior = .Ignore;
    srv.stdout_behavior = .Inherit;
    srv.stderr_behavior = .Inherit;
    // Enable passive teardown to reduce vendor crash risk in short-lived tests
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("GEODE_QUIC_PASSIVE_TEARDOWN", "1");
    srv.env_map = &env;
    try srv.spawn();
    defer {
        _ = srv.kill() catch {};
        _ = srv.wait() catch {};
    }

    // Small sleep to let server bind
    std.time.sleep(500 * std.time.ns_per_ms);

    util.progress("Running EXPLAIN query...", .{});
    // Client over QUIC targeting the server (QUIC is default, no --quic flag needed)
    const res = try run(allocator, &.{ geode, "query", "EXPLAIN RETURN 1 AS x", "--format", "json", "--server", addr, "--insecure" });
    defer allocator.free(res.out);
    defer allocator.free(res.err);

    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"explain\"") != null);

    util.testPass();
}
