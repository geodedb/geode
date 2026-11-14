const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;

fn runWithEnv(args: []const []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = try std.process.getEnvMap(testing.allocator);
    defer child.env_map.deinit();
    try child.env_map.put("GEODE_ADAPT_ESTIMATES", "1");
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 16);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 16);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    return out;
}

test "flags: adaptive estimates flag surfaces when env enabled" {
    const exe = geode_test_bin.geode_exe;
    const out = try runWithEnv(&.{ exe, "PROFILE RETURN 1 AS x LIMIT 1" });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "AdaptiveEstimatesPlanned") != null);
}
