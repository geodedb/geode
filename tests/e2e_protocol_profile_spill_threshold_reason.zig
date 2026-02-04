const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

fn runEnv(env_key: []const u8, env_val: []const u8, args: []const []const u8) ![]u8 {
    var env_map = std.process.EnvMap.init(testing.allocator);
    defer env_map.deinit();
    try env_map.put(env_key, env_val);
    var child = std.process.Child.init(args, testing.allocator);
    child.env_map = &env_map;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 18);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 16);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    return out;
}

test "protocol: spill_reason=threshold when peak exceeds threshold" {
    const exe = "./zig-out/bin/geode";
    // Very small threshold to guarantee crossing even minimal allocations
    const out = try runEnv("GEODE_SPILL_THRESHOLD_BYTES", "1", &.{ exe", "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1" });
    defer testing.allocator.free(out);
    // Find PROFILE line
    const pl = util.findProfileLine(out) orelse return error.MissingProfile;
    try testing.expect(std.mem.indexOf(u8, pl, "\"spill_reason\":\"threshold\"") != null);
}
