const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

test "protocol: PROFILE mem_curve present when flag enabled" {
    const out = try util.runProfile(testing.allocator, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1", &.{"GEODE_PROFILE_MEMCURVE=1"});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"mem_curve\":[") != null);
}
