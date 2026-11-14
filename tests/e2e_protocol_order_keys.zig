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

test "protocol: multiple ORDER BY keys emitted and stable for large payloads" {
    const exe = geode_test_bin.geode_exe;
    const q = "RETURN 1 AS a, 2 AS b, 3 AS c ORDER BY a, b, c LIMIT 1";
    const res = try run(&.{ exe, q });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"ordered\":true"));
    try std.testing.expect(contains(res.out, "\"order_keys\":[\"a\",\"b\",\"c\"]"));
}

test "protocol: ORDER BY keys preserved with long aliases" {
    const exe = geode_test_bin.geode_exe;
    var buf: [1024]u8 = undefined;
    const long = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ "abcdefghijklmnopqrstuvwxyz", "0123456789", "ABCDEFGHIJKLMNOPQRSTUVWXYZ" }) catch unreachable;
    const q = std.fmt.allocPrint(std.testing.allocator, "RETURN 1 AS {s}, 2 AS k ORDER BY {s}, k LIMIT 1", .{ long, long }) catch unreachable;
    defer std.testing.allocator.free(q);
    const res = try run(&.{ exe, q });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"ordered\":true"));
    // ensure the long alias shows up in order_keys
    try std.testing.expect(contains(res.out, long));
}
