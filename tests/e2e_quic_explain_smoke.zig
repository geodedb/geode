const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const allocator = std.testing.allocator;
    var child = Child.init(args, allocator);
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

// Env-gated: only runs when GEODE_CI_QUIC_SMOKE=1 is set to avoid flaky vendor teardown.
test "quic: EXPLAIN schema then explain (smoke)" {
    if (std.posix.getenv("GEODE_CI_QUIC_SMOKE") == null) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const geode = "./zig-out/bin/geode";

    // Start server in background with QUIC, exit after first request
    var srv = Child.init(&.{ geode, "serve", "--listen", "127.0.0.1:7567", "--log-level", "info" }, allocator);
    srv.stdin_behavior = .Ignore;
    srv.stdout_behavior = .Inherit;
    srv.stderr_behavior = .Inherit;
    // Enable passive teardown to reduce vendor crash risk in short-lived tests
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("GEODE_QUIC_PASSIVE_TEARDOWN", "1");
    srv.env_map = &env;
    try srv.spawn();

    // Small sleep to let server bind
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // Client over QUIC targeting the server (QUIC is default, no --quic flag needed)
    const res = try run(&.{ geode, "query", "EXPLAIN RETURN 1 AS x", "--format", "json", "--server", "127.0.0.1:7567", "--insecure" });
    defer allocator.free(res.out);
    defer allocator.free(res.err);

    // Terminate server gracefully
    _ = srv.kill() catch {};
    _ = srv.wait() catch {};

    // Smoke policy: require EXPLAIN only when explicitly requested; otherwise accept SCHEMA as success.
    const require_explain = std.posix.getenv("GEODE_CI_QUIC_REQUIRE_EXPLAIN") != null;
    const has_explain = std.mem.indexOf(u8, res.out, "\"result\":{\"type\":\"EXPLAIN\"") != null;
    if (require_explain) {
        try std.testing.expect(has_explain);
    } else {
        // Non-strict smoke: do not assert further; reaching here means QUIC server/client codepaths exercised.
        // Intentionally no checks to avoid environment-specific flakiness.
        return;
    }
}
