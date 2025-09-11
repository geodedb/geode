const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn runEnv(env_over: []const []const u8, args: []const []const u8) !struct { code: i32, out: []u8 } {
    const ally = std.testing.allocator;
    var child = Child.init(args, ally);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    // Apply overrides
    var env_map = try std.process.getEnvMap(ally);
    defer env_map.deinit();
    var i: usize = 0;
    while (i < env_over.len) : (i += 2) env_map.put(env_over[i], env_over[i + 1]) catch {};
    child.env_map = &env_map;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(ally, 1 << 20);
    _ = try child.stderr.?.readToEndAlloc(ally, 1 << 20);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = out };
}

fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

test "profile spills env simple" {
    const exe = "./zig-out/bin/geodec";
    const res = try runEnv(&.{ "GEODE_FORCE_SORT_SPILL", "1", "GEODE_FORCE_DISTINCT_SPILL", "2", "GEODE_FORCE_UNION_SPILL", "3" }, &.{ exe, "PROFILE RETURN 1 AS x" });
    defer std.testing.allocator.free(res.out);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"sort_spills\":1"));
    try std.testing.expect(contains(res.out, "\"distinct_spills\":1"));
    try std.testing.expect(contains(res.out, "\"union_spills\":1"));
}

test "profile spills env union" {
    const exe = "./zig-out/bin/geodec";
    const res = try runEnv(&.{ "GEODE_FORCE_UNION_SPILL", "7" }, &.{ exe, "PROFILE RETURN 1 AS x UNION RETURN 1 AS x" });
    defer std.testing.allocator.free(res.out);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"union_spills\":1")); // dedup path uses state.spill_union==1 when env present
}
