const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;
const util = @import("proto_test_util.zig");

fn run(allocator: std.mem.Allocator, args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(args[0]);
    if (args.len > 1 and !std.mem.eql(u8, args[1], "query")) {
        try argv.append("query");
    }
    try argv.appendSlice(args[1..]);
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

// CANARY: REQ=REQ-GQL-017; FEATURE="VarLen Path Determinism UA005/UA006"; ASPECT=ProtocolE2E_QUIC; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_VarLenDeterminism_QUIC; OWNER=engine; UPDATED=2025-09-24
test "protocol QUIC: MATCH varlen 1..2 determinism" {
    util.testStart("MATCH varlen 1..2 determinism (QUIC)");
    errdefer util.testFail();

    const allocator = std.testing.allocator;

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

    var server = Child.init(&.{ "./zig-out/bin/geode", "serve", "--listen", addr }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;
    server.env_map = &env;
    try server.spawn();
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    std.time.sleep(200 * std.time.ns_per_ms);

    util.progress("Running query...", .{});
    const res = try run(allocator, &.{ "./zig-out/bin/geode", "MATCH (a:Person)-[:KNOWS*1..2]->(b:Person) RETURN a.name AS a, b.name AS b ORDER BY a, b", "--server", addr, "--format", "json" });
    defer allocator.free(res.out);
    defer allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"ordered\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"order_keys\":[\"a\",\"b\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"a\":\"Alice\",\"b\":\"Bob\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"a\":\"Alice\",\"b\":\"Charlie\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"a\":\"Bob\",\"b\":\"Charlie\"}") != null);

    util.testPass();
}
