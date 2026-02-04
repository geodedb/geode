const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run_cdc() !struct { code: i32, out: []u8, err: []u8 } {
    const allocator = std.testing.allocator;

    // Start server with CDC enabled; exit after first request so test doesn't hang.
    var srv = Child.init(&.{ "./zig-out/bin/geode", "serve", "--listen", "127.0.0.1:8567 }, allocator);
    // Inherit stdout/stderr to help debug if needed (could redirect to Pipe if assertions need it later)
    srv.stdin_behavior = .Pipe;
    srv.stdout_behavior = .Inherit;
    srv.stderr_behavior = .Inherit;
    try srv.spawn();

    // Allow server to start (simple spin delay ~100ms)
    var i: usize = 0;
    while (i < 10_000_000) : (i += 1) {}

    // Issue CDC diagnostics request via stdio mode client (simplest path) with env enabling CDC.
    var cli = Child.init(&.{ "env", "GEODE_CDC_ENABLE=1", "./zig-out/bin/geode", "query", "--stdio" }, allocator);
    cli.stdin_behavior = .Pipe;
    cli.stdout_behavior = .Pipe;
    cli.stderr_behavior = .Pipe;
    try cli.spawn();

    // Send diagnostics frame request JSON line
    const req = "{\"type\":\"CDC_DIAGNOSTICS\"}\n";
    _ = try cli.stdin.?.write(req);
    cli.stdin.?.close();

    const out = try cli.stdout.?.readToEndAlloc(allocator, 1 << 20);
    const err = try cli.stderr.?.readToEndAlloc(allocator, 1 << 20);
    const term = try cli.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };

    // Best-effort terminate server (it may already have exited after first request)
    _ = srv.kill() catch {};
    _ = srv.wait() catch {};

    return .{ .code = code, .out = out, .err = err };
}

inline fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

// Protocol-level integration test: request CDC_DIAGNOSTICS via client stdio path.
// Assertions: presence of core fields from exportDiagnostics payload.
// NOTE: This relies on GEODE_CDC_ENABLE env variable being passed via 'env' invocation.

test "protocol: CDC diagnostics frame roundtrip" {
    const r = try run_cdc();
    defer std.testing.allocator.free(r.out);
    defer std.testing.allocator.free(r.err);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    // Expect JSON line with diagnostics result containing core keys
    try std.testing.expect(contains(r.out, "malformed_wal_records"));
    try std.testing.expect(contains(r.out, "total_wal_attempts"));
    try std.testing.expect(contains(r.out, "config"));
    try std.testing.expect(contains(r.out, "engine"));
    try std.testing.expect(contains(r.out, "timestamp_ms"));
}
