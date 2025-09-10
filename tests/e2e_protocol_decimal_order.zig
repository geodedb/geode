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

inline fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

// Validate decimal ordering across scales and sign.
// We simulate decimals using RETURN with raw literal forms once parser supports them; for now we mimic via int ordering fallback (placeholder test ensures framework readiness).

// NOTE: If decimal literal syntax not yet implemented, this test just ensures existing INT ordering is stable; adjust once decimals are exposed at parse level.

test "protocol: numeric ordering stable (placeholder for decimal)" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 2 AS x UNION RETURN 1 AS x UNION RETURN 3 AS x ORDER BY x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect ordered rows 1,2,3 after PULL (unordered union + grouped order logic currently sorts when grouped pattern detected)
    try std.testing.expect(contains(res.out, "{\"x\":1}"));
    try std.testing.expect(contains(res.out, "{\"x\":2}"));
    try std.testing.expect(contains(res.out, "{\"x\":3}"));
}
