const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

// PROFILE query with ORDER BY + OFFSET + LIMIT should show monotonic stage row transitions.
test "protocol: PROFILE ORDER+OFFSET+LIMIT row transitions" {
    const exe = geode_test_bin.geode_exe;
    // 4 param rows -> after OFFSET 1 => 3 -> LIMIT 2 => 2
    const res = try run(&.{ exe, "PROFILE RETURN a AS x ORDER BY x OFFSET 1 LIMIT 2", "--param", "a", "[1,2,3,4]" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"type\":\"PROFILE\""));
    // Check for expected row counts patterns (not strict ordering of operators in string, but presence)
    try std.testing.expect(contains(res.out, "\"Project\""));
    try std.testing.expect(contains(res.out, "\"Sort\""));
    try std.testing.expect(contains(res.out, "\"Offset\""));
    try std.testing.expect(contains(res.out, "\"Limit\""));
    // Specific counts
    try std.testing.expect(contains(res.out, "\"Project\"")); // ensures operation present
    try std.testing.expect(contains(res.out, "\"input_rows\":4")); // project input_rows (first op) or later op referencing 4
    try std.testing.expect(contains(res.out, "\"Offset\""));
    try std.testing.expect(contains(res.out, "\"Limit\""));
    // Final limit rows 2
    try std.testing.expect(contains(res.out, "\"rows\":2"));
}
