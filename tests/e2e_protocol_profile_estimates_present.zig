const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

test "protocol: PROFILE planner_estimates present (default)" {
    const out = try util.runProfile(testing.allocator, "PROFILE RETURN 1 AS x LIMIT 1", null);
    defer testing.allocator.free(out);
    const est_slice = util.slicePlannerEstimates(out) orelse return error.MissingPlannerEstimates;
    for ([_][]const u8{ "sum_estimate_bytes", "sum_actual_bytes", "count_estimated_ops", "min_error_abs_pct", "max_error_abs_pct", "stddev_error_abs_pct" }) |field| {
        var buf: [64]u8 = undefined;
        const pat = try std.fmt.bufPrint(&buf, "\"{s}\":", .{field});
        try testing.expect(std.mem.indexOf(u8, est_slice, pat) != null);
    }
    // Ensure block omitted only when --no-estimates flag is used (covered by another test).
}
