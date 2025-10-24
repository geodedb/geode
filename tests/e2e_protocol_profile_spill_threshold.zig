const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

test "profile: spill_reason=threshold when peak exceeds threshold" {
    const exe = "./zig-out/bin/geodec";
    var child = std.process.Child.init(&.{ exe, "PROFILE RETURN a AS x ORDER BY x LIMIT 2", "--json-param", "a", "[1,2,3,4,5,6,7,8,9,10]" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = try std.process.getEnvMap(testing.allocator);
    defer child.env_map.deinit();
    try child.env_map.put("GEODE_SPILL_THRESHOLD_BYTES", "64");
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 20);
    defer testing.allocator.free(out);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 16);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    const pl = util.findProfileLine(out) orelse return error.MissingProfile;
    try testing.expect(std.mem.indexOf(u8, pl, "\"spill_reason\":\"threshold\"") != null);
    try testing.expect(std.mem.indexOf(u8, pl, "peak_bytes_at_spill") != null);
}
