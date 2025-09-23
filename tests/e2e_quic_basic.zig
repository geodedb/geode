const std = @import("std");

// CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICBasicE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICBasicE2E; OWNER=wire; UPDATED=2025-09-22

const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run_quic() !struct { code: i32, out: []u8, err: []u8 } {
    const ally = std.testing.allocator;

    // Start server in QUIC mode
    var srv = Child.init(&.{ "./zig-out/bin/geoded", "--listen-quic", "127.0.0.1:7567", "--test-exit-after-first-request" }, ally);
    srv.stdin_behavior = .Inherit;
    srv.stdout_behavior = .Inherit;
    srv.stderr_behavior = .Inherit;
    try srv.spawn();

    // Give server a moment to start listening
    // simple delay loop ~100ms
    var i: usize = 0;
    while (i < 10_000_000) : (i += 1) {}

    // Client uses QUIC by default
    var cli = Child.init(&.{ "./zig-out/bin/geodec", "RETURN 1 AS x ORDER BY x LIMIT 1", "--server", "127.0.0.1:7567" }, ally);
    cli.stdin_behavior = .Ignore;
    cli.stdout_behavior = .Pipe;
    cli.stderr_behavior = .Pipe;
    try cli.spawn();

    const out = try cli.stdout.?.readToEndAlloc(ally, 1 << 20);
    const err = try cli.stderr.?.readToEndAlloc(ally, 1 << 20);
    const term = try cli.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };

    // Shutdown server: best effort
    _ = srv.kill() catch {};
    _ = srv.wait() catch {};

    return .{ .code = code, .out = out, .err = err };
}

// CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICProtocol; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICProtocol; OWNER=wire; UPDATED=2025-09-22
test "TestCANARY_REQ_GQL_074_QUICProtocol" {
    const r = try run_quic();
    defer std.testing.allocator.free(r.out);
    defer std.testing.allocator.free(r.err);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\"type\":\"SCHEMA\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\"type\":\"BINDINGS\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "{\"x\":1}") != null);
}
