const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8 } {
    const res = try cli_test_util.run(args);
    std.testing.allocator.free(res.err);
    return .{ .code = res.code, .out = res.out };
}

fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

// SONNY-6596: allocations are not measured on the version-1 path, so the
// fields are present and 0 (they were a fixed 64 bytes per invented
// operator: UnionLeft, UnionTails, SetOpUnion).
test "protocol: PROFILE UNION allocation fields present and unmeasured" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x UNION RETURN 1 AS x" });
    defer std.testing.allocator.free(res.out);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"op\":\"LegacyExecute\""));
    try std.testing.expect(!contains(res.out, "\"UnionLeft\""));
    try std.testing.expect(contains(res.out, "\"memory\":{\"net_bytes\":0,\"peak_bytes\":0,\"total_alloc_bytes\":0}"));
    try std.testing.expect(contains(res.out, "\"bytes_alloc\":0"));
    try std.testing.expect(contains(res.out, "\"percent_peak\":0"));
}
