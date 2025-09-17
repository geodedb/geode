const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run(gql: []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const ally = std.testing.allocator;
    var child = Child.init(&.{ "./zig-out/bin/geodec", gql, "--no-quic" }, ally);
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

test "setops mixed types and NULLs DISTINCT" {
    const gql = "RETURN NULL AS a, 'n' AS t UNION RETURN 42 AS a, 'i' AS t";
    const r = try run(gql);
    defer std.testing.allocator.free(r.out);
    defer std.testing.allocator.free(r.err);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\"ordered\":false") != null);
}
