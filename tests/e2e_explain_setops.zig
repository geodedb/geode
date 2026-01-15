const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn getServerAddr(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "GEODE_TEST_SERVER") catch return error.SkipZigTest;
}

fn run(gql: []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const allocator = std.testing.allocator;
    const server = try getServerAddr(allocator);
    defer allocator.free(server);
    var child = Child.init(&.{ "./zig-out/bin/geodec", gql, "--server", server, "--insecure" }, allocator);
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

test "EXPLAIN INTERSECT basic" {
    const r = try run("EXPLAIN RETURN 1 AS x INTERSECT RETURN 1 AS x");
    defer std.testing.allocator.free(r.out);
    defer std.testing.allocator.free(r.err);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\"type\":\"EXPLAIN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "SetOpIntersect") != null);
}

test "EXPLAIN EXCEPT basic" {
    const r = try run("EXPLAIN RETURN 1 AS x EXCEPT RETURN 1 AS x");
    defer std.testing.allocator.free(r.out);
    defer std.testing.allocator.free(r.err);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\"type\":\"EXPLAIN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "SetOpExcept") != null);
}
