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

// Regression: UNION DISTINCT should collapse 1, 1.0, 1.00 to a single row via canonical numeric key.
test "protocol: UNION DISTINCT canonical numeric dedup" {
    const exe = geode_test_bin.geode_exe;
    const q = "RETURN 1 AS x UNION RETURN 1.0 AS x UNION RETURN 1.00 AS x";
    const res = try run(&.{ exe, q });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect exactly one row in bindings: search for rows array and count occurrences of {"x":1}
    try std.testing.expect(contains(res.out, "\"rows\":[{\"x\":1}]"));
}
