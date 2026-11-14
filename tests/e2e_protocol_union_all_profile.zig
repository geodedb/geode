const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

// PROFILE UNION ALL should omit UnionDedup but still include left/tails and summary, and emit UnionPhaseTimings flag.
// Query: PROFILE RETURN 1 AS x UNION ALL RETURN 2 AS x

test "protocol: PROFILE UNION ALL phases without dedup" {
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x UNION ALL RETURN 2 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"op\":\"UnionLeft\""));
    try std.testing.expect(contains(res.out, "\"op\":\"UnionTails\""));
    try std.testing.expect(!contains(res.out, "\"op\":\"UnionDedup\""));
    try std.testing.expect(contains(res.out, "\"op\":\"SetOpUnion\""));
    try std.testing.expect(contains(res.out, "UnionPhaseTimings"));
}
