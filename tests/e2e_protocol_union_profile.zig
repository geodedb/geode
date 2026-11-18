const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

// SONNY-6596: a PROFILE of a UNION (the version-1 payload) reports the one
// statement the legacy executor ran, LegacyExecute, and the set operation's
// mode and output rows. It listed UnionLeft, UnionTails, UnionDedup and
// SetOpUnion with invented timings, and flagged U:UnionPhaseTimings; no
// UNION phase is timed, so neither is reported.
// Query: PROFILE RETURN 1 AS x UNION RETURN 1 AS x

test "protocol: PROFILE UNION DISTINCT reports the measured statement" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x UNION RETURN 1 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"op\":\"LegacyExecute\""));
    for ([_][]const u8{ "UnionLeft", "UnionTails", "UnionDedup", "SetOpUnion", "UnionPhaseTimings" }) |gone| {
        try std.testing.expect(!contains(res.out, gone));
    }
    try std.testing.expect(contains(res.out, "\"mode\":\"DISTINCT\""));
}
