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

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "planner: ORDER BY multi-keys" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 AS x, 2 AS y ORDER BY x, y LIMIT 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"ordered\":true"));
    try std.testing.expect(contains(res.out, "\"order_keys\":[\"x\",\"y\"]"));
}

test "planner: OFFSET with stable ORDER allowed" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 AS x ORDER BY x LIMIT 10 OFFSET 5" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"ordered\":true"));
}

test "planner: set op then ORDER BY LIMIT" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "(RETURN 2 AS x UNION RETURN 1 AS x) ORDER BY x LIMIT 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"ordered\":true"));
    try std.testing.expect(contains(res.out, "{\"x\":1}"));
}

test "planner: GROUP BY + HAVING + ORDER BY pipeline" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN a, COUNT(*) AS c GROUP BY a HAVING c > 1 ORDER BY c DESC LIMIT 1", "--json-param", "a", "[1,1,2]" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"ordered\":true"));
    try std.testing.expect(contains(res.out, "\"order_keys\":[\"c\"]"));
}
