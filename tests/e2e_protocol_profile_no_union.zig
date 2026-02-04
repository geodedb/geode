const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "protocol: PROFILE simple query has no UnionPhaseTimings flag" {
    const exe = "./zig-out/bin/geode";
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x LIMIT 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Should have PROFILE ops but no UnionPhaseTimings flag or union phase ops
    try std.testing.expect(contains(res.out, "\"type\":\"PROFILE\""));
    try std.testing.expect(!contains(res.out, "UnionPhaseTimings"));
    try std.testing.expect(!contains(res.out, "\"op\":\"UnionLeft\""));
}
