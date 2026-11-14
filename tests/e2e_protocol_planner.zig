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

test "planner: ORDER BY multi-keys" {
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "RETURN 1 AS x, 2 AS y ORDER BY x, y LIMIT 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"ordered\":true"));
    try std.testing.expect(contains(res.out, "\"order_keys\":[\"x\",\"y\"]"));
}

test "planner: OFFSET with stable ORDER allowed" {
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "RETURN 1 AS x ORDER BY x LIMIT 10 OFFSET 5" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"ordered\":true"));
}

// SONNY-6548: two cases were dropped. "(RETURN 2 AS x UNION RETURN 1 AS x)
// ORDER BY x LIMIT 1" is not GQL (a <composite query expression> operand is a
// linear query statement, not a parenthesized query; 42000), and the GROUP
// BY + HAVING case relied on the deleted client expanding an array --param
// into one row per element. ORDER BY after FOR ... GROUP BY loses its
// metadata: tests/test_sonny6548_wire_result_metadata.zig.
