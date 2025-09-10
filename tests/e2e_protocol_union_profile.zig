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

// PROFILE UNION DISTINCT should show granular phase ops and UnionPhaseTimings flag.
// Query: PROFILE (RETURN 1 AS x UNION RETURN 1 AS x)
// We expect ops: UnionLeft, UnionTails, UnionDedup, SetOpUnion
// and flagger_findings includes U:UnionPhaseTimings.

test "protocol: PROFILE UNION DISTINCT granular phases" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x UNION RETURN 1 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"op\":\"UnionLeft\""));
    try std.testing.expect(contains(res.out, "\"op\":\"UnionTails\""));
    try std.testing.expect(contains(res.out, "\"op\":\"UnionDedup\""));
    try std.testing.expect(contains(res.out, "\"op\":\"SetOpUnion\""));
    try std.testing.expect(contains(res.out, "UnionPhaseTimings"));
}
