const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");
const testing = std.testing;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

inline fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

// Expect TypeMismatch diagnostic (division by zero) with anchor possibly empty.

test "protocol: division by zero TypeMismatch" {
    const exe = "./zig-out/bin/geode";
    const res = try run(&.{ exe, "RETURN 1/0 AS x" });
    // Error expected
    try testing.expect(res.code == 2);
    try testing.expect(contains(res.err, "TypeMismatch"));
}
