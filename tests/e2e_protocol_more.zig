const std = @import("std");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const ally = std.testing.allocator;
    var child = std.ChildProcess.init(args, ally);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(ally, 1 << 20);
    const err = try child.stderr.?.readToEndAlloc(ally, 1 << 20);
    const term = try child.wait();
    return .{ .code = term.Exited, .out = out, .err = err };
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "protocol: ORDER BY alias and ordinal" {
    const exe = "./zig-out/bin/geodec";
    const res1 = try run(&.{ exe, "RETURN 1 AS x, 2 AS y ORDER BY y LIMIT 1" });
    defer std.testing.allocator.free(res1.out);
    defer std.testing.allocator.free(res1.err);
    try std.testing.expectEqual(@as(i32, 0), res1.code);
    try std.testing.expect(contains(res1.out, "\"ordered\":true"));
    try std.testing.expect(contains(res1.out, "\"order_keys\":[\"y\"]"));

    const res2 = try run(&.{ exe, "RETURN 1 AS x, 2 AS y ORDER BY 2 LIMIT 1" });
    defer std.testing.allocator.free(res2.out);
    defer std.testing.allocator.free(res2.err);
    try std.testing.expectEqual(@as(i32, 0), res2.code);
    try std.testing.expect(contains(res2.out, "\"ordered\":true"));
}

test "protocol: aggregates ORDER BY alias" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN SUM(v) AS s ORDER BY s LIMIT 1", "--json-param", "v", "[3,2,1]" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"ordered\":true"));
    try std.testing.expect(contains(res.out, "\"order_keys\":[\"s\"]"));
}

test "protocol: set ops LIMIT without ORDER triggers US001" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 AS x UNION RETURN 2 AS x LIMIT 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(contains(res.err, "US001"));
}

test "protocol: GROUP BY illegality surfaces diagnostics" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN a, SUM(b) GROUP BY a, b" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(contains(res.err, "GroupByIllegal"));
    try std.testing.expect(contains(res.err, "14.10"));
}
