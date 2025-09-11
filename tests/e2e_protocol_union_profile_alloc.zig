const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run(args: []const []const u8) !struct { code: i32, out: []u8 } {
    var child = Child.init(args, std.testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(std.testing.allocator, 1 << 16);
    _ = try child.stderr.?.readToEndAlloc(std.testing.allocator, 1 << 16);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = out };
}

fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

test "protocol: PROFILE UNION allocation deltas present" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x UNION RETURN 1 AS x" });
    defer std.testing.allocator.free(res.out);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"UnionLeft\""));
    try std.testing.expect(contains(res.out, "\"UnionTails\""));
    try std.testing.expect(contains(res.out, "\"SetOpUnion\""));
    try std.testing.expect(contains(res.out, "\"memory\""));
    try std.testing.expect(contains(res.out, "\"bytes_alloc\""));
    try std.testing.expect(contains(res.out, "\"percent_peak\""));
}
