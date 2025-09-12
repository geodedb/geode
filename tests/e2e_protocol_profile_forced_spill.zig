const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

fn runWithEnv(args: []const []const u8, env_map: *std.process.EnvMap) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = env_map; // ensure forced spill env variable is visible to server
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 18);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 16);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    return out;
}

test "protocol: forced spill reason appears when env forces spill" {
    const exe = "zig-out/bin/geoded";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Force spill for sort via env variable. Volume large enough to trigger a sort and spill single op.
    var env_map = std.process.EnvMap.init(alloc);
    defer env_map.deinit();
    try env_map.put("GEODE_FORCE_SORT_SPILL", "1");
    const q = "PROFILE RETURN a AS x ORDER BY x LIMIT 5";
    const out = try runWithEnv(&.{ exe, q, "--json-param", "a", "[5,4,3,2,1]" }, &env_map);
    defer testing.allocator.free(out);
    const pl = util.findProfileLine(out) orelse return error.MissingProfile;
    // We expect spill_reason forced and sort_spills >=1
    try testing.expect(std.mem.indexOf(u8, pl, "\"spill_reason\":\"forced\"") != null);
    try testing.expect(std.mem.indexOf(u8, pl, "\"sort_spills\":1") != null or std.mem.indexOf(u8, pl, "\"sort_spills\":2") != null);
}
