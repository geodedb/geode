const std = @import("std");
const testing = std.testing;

test "protocol: PROFILE adaptive estimates flag when env enabled" {
    const exe = "./zig-out/bin/geodec";
    var child = std.process.Child.init(&.{ exe, "PROFILE RETURN 1 AS x LIMIT 1" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = try std.process.getEnvMap(testing.allocator);
    defer child.env_map.deinit();
    try child.env_map.put("GEODE_ADAPT_ESTIMATES", "1");
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 16);
    defer testing.allocator.free(out);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 12);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    // Expect flag in SCHEMA (first frame) or PROFILE (second). Just search entire output.
    try testing.expect(std.mem.indexOf(u8, out, "U:AdaptiveEstimatesPlanned") != null);
}
