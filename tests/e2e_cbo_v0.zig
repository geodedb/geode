const std = @import("std");
const cbo = @import("geode").cbo_api_stub;

// Basic CBO API exposure tests; requires GEODE_ENABLE_CBO for full behavior.

test "choosePlanAPI disabled returns FeatureDisabled" {
    try std.testing.expectError(error.FeatureDisabled, cbo.choosePlanAPI());
}

test "explainEstimateJSON disabled includes cbo_enabled false" {
    const s = try cbo.explainEstimateJSON(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"cbo_enabled\":false") != null);
}

test "explainEstimateJSON enabled includes plan and summary" {
    cbo.enableForTests();
    defer cbo.disableForTests();
    const s = try cbo.explainEstimateJSON(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"cbo_enabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"plan\":") != null);
}
