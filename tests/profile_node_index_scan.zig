const std = @import("std");
const testing = std.testing;

fn run(args: []const []const u8) !struct { code: i32, out: []u8 } {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 16);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 16);
    const term = try child.wait();
    return .{ .code = if (term == .Exited) term.Exited else 2, .out = out };
}

test "profile includes NodeIndexScan heuristic" {
    const exe = "./zig-out/bin/geode";
    const q = "PROFILE RETURN 1 WHERE 1=1"; // trivial predicate triggers heuristic
    const res = try run(&.{ exe, q });
    try testing.expectEqual(@as(i32, 0), res.code);
    try testing.expect(std.mem.indexOf(u8, res.out, "NodeIndexScan") != null);
}
