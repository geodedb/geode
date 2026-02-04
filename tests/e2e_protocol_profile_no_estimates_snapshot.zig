const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

test "protocol: PROFILE --no-estimates structural stability" {
    const out = try util.runProfile(testing.allocator, "PROFILE RETURN 1 AS x LIMIT 1", &.{"GEODE_DISABLE_ESTIMATES=1"});
    defer testing.allocator.free(out);
    // Ensure planner_estimates block removed or zeroed (with --no-estimates we expect omission)
    try testing.expect(std.mem.indexOf(u8, out, "\"planner_estimates\"") == null);
    // Ensure other mandatory fields exist
    try testing.expect(std.mem.indexOf(u8, out, "\"ops\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"memory\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"flagger_findings\":") != null);
}
