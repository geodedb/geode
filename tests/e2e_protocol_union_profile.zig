const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

// PROFILE UNION DISTINCT should show granular phase ops and UnionPhaseTimings flag.
// Query: PROFILE (RETURN 1 AS x UNION RETURN 1 AS x)
// We expect ops: UnionLeft, UnionTails, UnionDedup, SetOpUnion
// and flagger_findings includes U:UnionPhaseTimings.

test "protocol: PROFILE UNION DISTINCT granular phases" {
    const exe = "./zig-out/bin/geode";
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
