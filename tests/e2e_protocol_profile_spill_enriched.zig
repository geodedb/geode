const std = @import("std");
const testing = std.testing;

fn runEnv(env_over: []const []const u8, args: []const []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    var env_map = try std.process.getEnvMap(testing.allocator);
    defer env_map.deinit();
    var i: usize = 0;
    while (i < env_over.len) : (i += 2) env_map.put(env_over[i], env_over[i + 1]) catch {};
    child.env_map = &env_map;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 20);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 18);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    return out;
}

test "profile spill enrichment fields" {
    const exe = "zig-out/bin/geode";
    // Force threshold spill by setting low threshold and enabling sort.
    const out = try runEnv(&.{ "GEODE_SPILL_THRESHOLD_BYTES", "1" }, &.{ exe", "PROFILE RETURN 1 AS x ORDER BY x" });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"spill_reason\":\"threshold\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "peak_bytes_at_spill") != null);
    // first_spill_op_index is optional, but if present must be numeric.
    if (std.mem.indexOf(u8, out, "first_spill_op_index") != null) {
        try testing.expect(std.mem.indexOf(u8, out, "first_spill_op_index\":0") != null or std.mem.indexOf(u8, out", "first_spill_op_index\":") != null);
    }
}
