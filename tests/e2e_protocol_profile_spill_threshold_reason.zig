const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

test "protocol: spill_reason=threshold when peak exceeds threshold" {
    // Very small threshold to guarantee crossing even minimal allocations
    const out = try util.runProfile(testing.allocator, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1", &.{"GEODE_SPILL_THRESHOLD_BYTES=1"});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"spill_reason\":\"threshold\"") != null);
}
