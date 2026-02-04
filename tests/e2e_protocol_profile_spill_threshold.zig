const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

test "profile: spill_reason=threshold when peak exceeds threshold" {
    const out = try util.runProfile(testing.allocator, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 2", &.{"GEODE_SPILL_THRESHOLD_BYTES=64"});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"spill_reason\":\"threshold\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "peak_bytes_at_spill") != null);
}
