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

// Ensure numeric 1 and string "1" are NOT collapsed by canonical numeric dedup in UNION DISTINCT.
test "protocol: UNION DISTINCT keeps numeric vs string distinct" {
    const exe = geode_test_bin.geode_exe;
    const q = "RETURN 1 AS x UNION RETURN \"1\" AS x";
    const res = try run(&.{ exe, q });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect two rows: one numeric, one string. Rows order may vary, so check both forms appear.
    try std.testing.expect(contains(res.out, "{\"x\":1}"));
    try std.testing.expect(contains(res.out, "{\"x\":\"1\"}"));
    // And ensure not collapsed into single row: look for closing array with only one element pattern
    try std.testing.expect(!contains(res.out, "\"rows\":[{\"x\":1}]"));
}
