const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

// Ensures mem_curve is not emitted unless explicitly requested
// (negative counterpart to memcurve presence tests)

test "protocol: PROFILE mem_curve absent by default" {
    const out = try util.runProfile(testing.allocator, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1", null);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"mem_curve\":") == null);
}
