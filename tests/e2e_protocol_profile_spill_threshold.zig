const std = @import("std");
const testing = std.testing;

fn runWithEnv(cmd: []const []const u8, env_key: []const u8, env_val: []const u8) !struct { out: []u8 } {
    var child = std.process.Child.init(cmd, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    // Inherit base env then append threshold variable.
    var env_map = try std.process.getEnvMap(testing.allocator);
    defer env_map.deinit();
    try env_map.put(env_key, env_val);
    var it = env_map.iterator();
    var env_kv = std.ArrayList([]const u8).init(testing.allocator);
    defer env_kv.deinit();
    while (it.next()) |e| {
        const line = try std.fmt.allocPrint(testing.allocator, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* });
        try env_kv.append(line);
    }
    child.env_map = &env_kv;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 16);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 16);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    // free env strings
    for (env_kv.items) |kv| testing.allocator.free(kv);
    return .{ .out = out };
}

test "protocol: PROFILE spill threshold triggers spill counters" {
    const exe = "zig-out/bin/geoded";
    // Very low threshold (1 byte) ensures any allocation triggers spills for appropriate stages.
    const res = try runWithEnv(&.{ exe, "PROFILE RETURN a AS x DISTINCT ORDER BY x OFFSET 1 LIMIT 1", "--json-param", "a", "[1,2,3]" }, "GEODE_SPILL_THRESHOLD_BYTES", "1");
    defer testing.allocator.free(res.out);
    var it = std.mem.splitScalar(u8, res.out, '\n');
    _ = it.next();
    const profile_line = it.next() orelse return error.MissingProfileLine;
    try testing.expect(std.mem.indexOf(u8, profile_line, "\"spills\"") != null);
    // Should mark sort_spills or distinct_spills (both may be 1). We just assert at least one non-zero.
    const has_sort = std.mem.indexOf(u8, profile_line, "\"sort_spills\":1") != null;
    const has_distinct = std.mem.indexOf(u8, profile_line, "\"distinct_spills\":1") != null;
    try testing.expect(has_sort or has_distinct);
}
