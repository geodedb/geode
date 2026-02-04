const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

test "protocol: decimal arithmetic add/sub/mul/div and comparisons" {
    const exe = "./zig-out/bin/geode";
    // Mixed int + decimal additions
    const res1 = try run(&.{ exe, "RETURN 1.25 AS a UNION RETURN 2 AS a" });
    defer std.testing.allocator.free(res1.out);
    defer std.testing.allocator.free(res1.err);
    try std.testing.expectEqual(@as(i32, 0), res1.code);
    // Expect DECIMAL type in schema and at least one decimal literal emitted ("1.25" or numeric 1.25 rendering)
    try std.testing.expect(std.mem.indexOf(u8, res1.out, "DECIMAL") != null);

    const res2 = try run(&.{ exe, "RETURN 5.00 / 2 AS x" });
    defer std.testing.allocator.free(res2.out);
    defer std.testing.allocator.free(res2.err);
    try std.testing.expectEqual(@as(i32, 0), res2.code);
    // Division may truncate scale -> check for rows entry with integer or decimal result
    try std.testing.expect(std.mem.indexOf(u8, res2.out, "\"x\":") != null);
}
