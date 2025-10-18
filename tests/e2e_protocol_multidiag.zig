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

inline fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

// This query triggers an IllegalOrderKey (function call) plus pagination (LIMIT) with invalid ORDER BY;
// heuristic should surface US001 in additional_statuses.
// Expected: exit code 2, stderr line contains both "IllegalOrderKey" and "additional_statuses" and "US001".

test "protocol: multi-diagnostic IllegalOrderKey + US001 additional" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN a ORDER BY f(a) LIMIT 5" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(contains(res.err, "IllegalOrderKey"));
    try std.testing.expect(contains(res.err, "additional_statuses"));
    try std.testing.expect(contains(res.err, "US001"));
    try std.testing.expect(contains(res.err, "US001/enforced"));
}
