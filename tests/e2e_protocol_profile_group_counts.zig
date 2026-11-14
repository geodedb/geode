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

// Ensure AggregateBuild shows non-zero input_rows when params provide multiple rows.
test "protocol: PROFILE GROUP BY shows agg_rows_in from params" {
    const exe = geode_test_bin.geode_exe;
    // Provide param array a with three values; query groups by a returning a and COUNT(*)
    const res = try run(&.{ exe, "PROFILE RETURN a, COUNT(*) AS c GROUP BY a", "--param", "a", "[1,1,2]" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"type\":\"PROFILE\""));
    try std.testing.expect(contains(res.out, "AggregateBuild"));
    // Expect input_rows >= 3 (param rows) and rows (groups) == 2 (values 1 & 2) in JSON substring.
    try std.testing.expect(contains(res.out, "\"AggregateBuild\""));
    try std.testing.expect(contains(res.out, "\"input_rows\":3"));
    // Group count 2 (distinct values) may appear in AggregateEmit rows field; assert rows":2 occurs
    try std.testing.expect(contains(res.out, "\"rows\":2"));
}
