const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");
const testing = std.testing;

fn run(args: []const []const u8) !struct { out: []u8 } {
    const res = try cli_test_util.run(args);
    std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    return .{ .out = res.out };
}

// SONNY-6596: the version-1 payload counts a UNION's output rows only. The
// fill percentage was output / (part count x output rows), an invented
// input; with no measured input it is absent and the dedup size 0.
test "protocol: PROFILE UNION DISTINCT reports its output rows, no invented fill" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x UNION RETURN 1 AS x" });
    defer testing.allocator.free(res.out);
    try testing.expect(std.mem.indexOf(u8, res.out, "\"setop\":{\"type\":\"UNION\",\"mode\":\"DISTINCT\",\"input_rows\":0,\"output_rows\":1,\"hash_dedup_size\":0}") != null);
    try testing.expect(std.mem.indexOf(u8, res.out, "\"distinct_fill_pct\"") == null);
}
