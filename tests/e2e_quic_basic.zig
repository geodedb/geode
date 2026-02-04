const std = @import("std");
const util = @import("proto_test_util.zig");

// CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICBasicE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICBasicE2E; OWNER=wire; UPDATED=2025-09-22

const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run_quic(allocator: std.mem.Allocator, addr: []const u8) !struct { code: i32, out: []u8, err: []u8, server: ?*Child } {
    // Start server in QUIC mode
    var srv = Child.init(&.{ "./zig-out/bin/geode", "serve", "--listen", addr }, allocator);
    srv.stdin_behavior = .Inherit;
    srv.stdout_behavior = .Inherit;
    srv.stderr_behavior = .Inherit;
    try srv.spawn();

    // Wait for server to be ready
    std.time.sleep(200 * std.time.ns_per_ms);

    // Client uses QUIC by default
    var cli = Child.init(&.{ "./zig-out/bin/geode", "query", "RETURN 1 AS x ORDER BY x LIMIT 1", "--server", addr }, allocator);
    cli.stdin_behavior = .Ignore;
    cli.stdout_behavior = .Pipe;
    cli.stderr_behavior = .Pipe;
    try cli.spawn();

    const out = try cli.stdout.?.readToEndAlloc(allocator, 1 << 20);
    const err = try cli.stderr.?.readToEndAlloc(allocator, 1 << 20);
    const term = try cli.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };

    // Shutdown server: best effort
    _ = srv.kill() catch {};
    _ = srv.wait() catch {};

    return .{ .code = code, .out = out, .err = err, .server = null };
}

// CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICProtocol; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICProtocol; OWNER=wire; UPDATED=2025-09-22
test "TestCANARY_REQ_GQL_074_QUICProtocol" {
    util.testStart("QUIC Protocol basic");
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

    util.progress("Starting QUIC server on port {d}...", .{port});
    const r = try run_quic(allocator, addr);
    defer allocator.free(r.out);
    defer allocator.free(r.err);

    util.progress("Verifying response...", .{});
    try std.testing.expectEqual(@as(i32, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\"rows\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "{\"x\":1}") != null);

    util.testPass();
}
