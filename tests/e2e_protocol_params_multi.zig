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

test "protocol: multi param aligned arrays" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN a AS a, b AS b", "--json-param", "a", "[1,2]", "--json-param", "b", "[3,4]" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"a\":1,\"b\":3}") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"a\":2,\"b\":4}") != null);
}

test "protocol: multi param length mismatch" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN a AS a, b AS b", "--json-param", "a", "[1,2]", "--json-param", "b", "[9]" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "TypeMismatch") != null);
}
