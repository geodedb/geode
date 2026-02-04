const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

test "protocol: spill reason appears when threshold exceeded" {
    // Force spill for sort via threshold. Volume large enough to trigger a sort and spill single op.
    const out = try util.runProfile(testing.allocator, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 5", &.{"GEODE_SPILL_THRESHOLD_BYTES=1"});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"spill_reason\":\"threshold\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"sort_spills\":1") != null);
}
