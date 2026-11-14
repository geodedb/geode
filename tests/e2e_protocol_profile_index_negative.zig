const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");
const testing = std.testing;

fn run(args: []const []const u8) !struct { code: i32, out: []u8 } {
    const res = try cli_test_util.run(args);
    std.testing.allocator.free(res.err);
    return .{ .code = res.code, .out = res.out };
}

test "profile heuristic does not emit NodeIndexScan without predicate" {
    const exe = geode_test_bin.geode_exe;
    const q = "PROFILE RETURN 1 AS x";
    const res = try run(&.{ exe, q });
    try testing.expectEqual(@as(i32, 0), res.code);
    try testing.expect(std.mem.indexOf(u8, res.out, "NodeIndexScan") == null);
}
