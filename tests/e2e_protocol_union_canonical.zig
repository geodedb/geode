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

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

// Regression: UNION DISTINCT should collapse 1, 1.0, 1.00 to a single row via canonical numeric key.
test "protocol: UNION DISTINCT canonical numeric dedup" {
    const exe = "./zig-out/bin/geodec";
    const q = "RETURN 1 AS x UNION RETURN 1.0 AS x UNION RETURN 1.00 AS x";
    const res = try run(&.{ exe, q });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect exactly one row in bindings: search for rows array and count occurrences of {"x":1}
    try std.testing.expect(contains(res.out, "\"rows\":[{\"x\":1}]"));
}
