const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

// Ensures mem_curve is not emitted unless explicitly requested
// (negative counterpart to memcurve presence tests)

test "protocol: PROFILE mem_curve absent by default" {
    const exe = "./zig-out/bin/geodec";
    const out = try util.runCli(testing.allocator, &.{ exe, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1" });
    defer testing.allocator.free(out);
    const pl = util.findProfileLine(out) orelse return error.MissingProfile;
    try testing.expect(std.mem.indexOf(u8, pl, "\"mem_curve\":") == null);
}
