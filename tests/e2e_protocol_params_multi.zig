const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

test "protocol: multi param aligned arrays" {
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "RETURN a AS a, b AS b", "--param", "a", "[1,2]", "--param", "b", "[3,4]" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"a\":1,\"b\":3}") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"a\":2,\"b\":4}") != null);
}

test "protocol: multi param length mismatch" {
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "RETURN a AS a, b AS b", "--param", "a", "[1,2]", "--param", "b", "[9]" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "TypeMismatch") != null);
}
