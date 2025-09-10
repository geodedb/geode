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

inline fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "protocol: US001 error includes flagger findings" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 LIMIT 5 OFFSET 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(contains(res.err, "US001"));
    try std.testing.expect(contains(res.err, "flagger_findings"));
    try std.testing.expect(contains(res.err, "U:US001/enforced"));
}

test "protocol: IllegalOrderKey error includes ident-only policy flag" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN a ORDER BY f(a)" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(contains(res.err, "IllegalOrderKey"));
    try std.testing.expect(contains(res.err, "I:IllegalOrderKeyPolicy=ident-only"));
}

test "flags: DISTINCT unordered emits DistinctOutputUnordered" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 AS x UNION RETURN 1 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "DistinctOutputUnordered"));
}

test "flags: ordered query has OrderTiebreak but not DistinctOutputUnordered" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 AS x ORDER BY x LIMIT 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "OrderTiebreak=LexJSON"));
    try std.testing.expect(!contains(res.out, "DistinctOutputUnordered"));
}

test "flags: NullsFirstPolicy present in DISTINCT unordered set where NULL participates" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN null AS a UNION RETURN 1 AS a" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "NullsFirstPolicy"));
}

test "flags: EXPLAIN includes base policy flags" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "EXPLAIN RETURN 1 AS x ORDER BY x LIMIT 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"type\":\"EXPLAIN\""));
    try std.testing.expect(contains(res.out, "IllegalOrderKeyPolicy=ident-only"));
    try std.testing.expect(contains(res.out, "OrderTiebreak=LexJSON"));
}

test "flags: PROFILE includes base policy flags and per-op timings" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"type\":\"PROFILE\""));
    try std.testing.expect(contains(res.out, "OrderTiebreak=LexJSON"));
    // Expect total_time_ns and at least one op timing key
    try std.testing.expect(contains(res.out, "total_time_ns"));
    try std.testing.expect(contains(res.out, "\"op\":\"Project\""));
}

test "flags: transaction ACK frames carry policy flags" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 AS x", "--begin", "--commit" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "IllegalOrderKeyPolicy=ident-only"));
}
