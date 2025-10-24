const std = @import("std");
const cbo = @import("geode").cbo_api_stub;

// Basic CBO API exposure tests; requires GEODE_ENABLE_CBO for full behavior.

test "explainEstimateJSON includes plan and summary (always enabled)" {
    const s = try cbo.explainEstimateJSON(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"cbo_enabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"plan\":") != null);
}
