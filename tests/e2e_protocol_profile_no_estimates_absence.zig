const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("profile_test_util.zig");

test "protocol: PROFILE --no-estimates omits planner_estimates" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const out = try util.runProfile(testing.allocator, "PROFILE RETURN 1 AS x LIMIT 1", &.{"GEODE_DISABLE_ESTIMATES=1"});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"planner_estimates\"") == null);
    // Ensure none of the key fields appear at top-level either
    inline for ([_][]const u8{ "sum_estimate_bytes", "sum_actual_bytes", "count_estimated_ops" }) |k| {
        try testing.expect(std.mem.indexOf(u8, out, k) == null);
    }
}
