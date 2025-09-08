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

test "protocol: multiple ORDER BY keys emitted and stable for large payloads" {
    const exe = "./zig-out/bin/geodec";
    const q = "RETURN 1 AS a, 2 AS b, 3 AS c ORDER BY a, b, c LIMIT 1";
    const res = try run(&.{ exe, q });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"ordered\":true"));
    try std.testing.expect(contains(res.out, "\"order_keys\":[\"a\",\"b\",\"c\"]"));
}

test "protocol: ORDER BY keys preserved with long aliases" {
    const exe = "./zig-out/bin/geodec";
    var buf: [1024]u8 = undefined;
    const long = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{"abcdefghijklmnopqrstuvwxyz","0123456789","ABCDEFGHIJKLMNOPQRSTUVWXYZ"}) catch unreachable;
    const q = std.fmt.allocPrint(std.testing.allocator, "RETURN 1 AS {s}, 2 AS k ORDER BY {s}, k LIMIT 1", .{ long, long }) catch unreachable;
    defer std.testing.allocator.free(q);
    const res = try run(&.{ exe, q });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"ordered\":true"));
    // ensure the long alias shows up in order_keys
    try std.testing.expect(contains(res.out, long));
}
