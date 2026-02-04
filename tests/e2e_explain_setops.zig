const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;
const proto_util = @import("proto_test_util.zig");

fn run(server: []const u8, gql: []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const allocator = std.testing.allocator;
    var child = Child.init(&.{ "./zig-out/bin/geode", "query", gql, "--server", server, "--insecure" }, allocator);
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
    var server = try proto_util.spawnServerRandom(std.testing.allocator, proto_util.TestEnv.standard());
    defer server.deinit();
    const r = try run(server.getAddr(), "EXPLAIN RETURN 1 AS x INTERSECT RETURN 1 AS x");
    defer std.testing.allocator.free(r.out);
    defer std.testing.allocator.free(r.err);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\"type\":\"EXPLAIN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "SetOpIntersect") != null);
}

test "EXPLAIN EXCEPT basic" {
    var server = try proto_util.spawnServerRandom(std.testing.allocator, proto_util.TestEnv.standard());
    defer server.deinit();
    const r = try run(server.getAddr(), "EXPLAIN RETURN 1 AS x EXCEPT RETURN 1 AS x");
    defer std.testing.allocator.free(r.out);
    defer std.testing.allocator.free(r.err);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\"type\":\"EXPLAIN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "SetOpExcept") != null);
}
