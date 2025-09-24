const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const ally = std.testing.allocator;
    var child = Child.init(args, ally);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(ally, 1 << 20);
    const err = try child.stderr.?.readToEndAlloc(ally, 1 << 20);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = out, .err = err };
}

// Env-gated: only runs when GEODE_CI_QUIC_SMOKE=1 is set to avoid flaky vendor teardown.
test "quic: EXPLAIN schema then explain (smoke)" {
    if (std.posix.getenv("GEODE_CI_QUIC_SMOKE") == null) return error.SkipZigTest;

    const ally = std.testing.allocator;
    const server = "./zig-out/bin/geoded";

    // Start server in background with QUIC, exit after first request
    var srv = Child.init(&.{ server, "--listen-quic", "127.0.0.1:7567", "--log_json", "--result-format", "json", "--test-exit-after-first-request" }, ally);
    srv.stdin_behavior = .Ignore;
    srv.stdout_behavior = .Inherit;
    srv.stderr_behavior = .Inherit;
    try srv.spawn();

    // Small sleep to let server bind
    std.Thread.sleep(150 * std.time.ns_per_ms);

    // Client over QUIC targeting the server
    const cli = "./zig-out/bin/geodec";
    const res = try run(&.{ cli, "EXPLAIN RETURN 1 AS x", "--format", "json", "--quic", "--server", "127.0.0.1:7567" });
    defer ally.free(res.out);
    defer ally.free(res.err);

    // Terminate server (it should exit after first request)
    _ = try srv.wait();

    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect SCHEMA followed by EXPLAIN frame
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\n{\"status_class\":\"00000\",\"result\":{\"type\":\"EXPLAIN\"") != null);
}
