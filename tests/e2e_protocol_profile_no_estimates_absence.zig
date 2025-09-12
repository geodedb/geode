const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

test "protocol: PROFILE --no-estimates omits planner_estimates" {
    const exe = "./zig-out/bin/geodec";
    const out = try util.runCli(testing.allocator, &.{ exe, "PROFILE RETURN 1 AS x LIMIT 1", "--no-estimates" });
    defer testing.allocator.free(out);
    const pl = util.findProfileLine(out) orelse return error.MissingProfile;
    try testing.expect(std.mem.indexOf(u8, pl, "\"planner_estimates\"") == null);
    // Ensure none of the key fields appear at top-level either
    inline for ([_][]const u8{ "sum_estimate_bytes", "sum_actual_bytes", "count_estimated_ops" }) |k| {
        try testing.expect(std.mem.indexOf(u8, pl, k) == null);
    }
}
