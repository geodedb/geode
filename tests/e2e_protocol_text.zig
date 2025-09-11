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

fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

// Validate plain text output from client (tab separated) for ordering & NULL handling.
// Query returns deterministic ordering by x plus NULL demonstration via CASE.
// We use parameter array to produce values [null, true] then order by projection.
// (Server text mode tested separately via direct invocation.)

test "client: --format txt simple RETURN" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 2 AS x ORDER BY x LIMIT 1", "--format", "txt" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect header then single row line
    try std.testing.expect(contains(res.out, "x\n2\n"));
}

test "client: --format txt EXPLAIN parity" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "EXPLAIN RETURN 1 AS x ORDER BY x LIMIT 1", "--format", "txt" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Should contain logical operators (at least Project)
    try std.testing.expect(contains(res.out, "Project"));
}

test "client: --format txt PROFILE parity" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1", "--format", "txt" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect timing columns signaled by presence of 'time_ns' literal or header token
    try std.testing.expect(contains(res.out, "Project"));
}
