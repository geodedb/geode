const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8 } {
    const res = try cli_test_util.run(args);
    std.testing.allocator.free(res.err);
    return .{ .code = res.code, .out = res.out };
}

fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

test "protocol: PROFILE UNION allocation deltas present" {
    const exe = "./zig-out/bin/geode";
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
