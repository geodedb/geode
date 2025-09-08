const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;
const E = struct {
    fn run_with_env(args: []const []const u8, envs: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
        const ally = std.testing.allocator;
        var child = Child.init(args, ally);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.env_map = std.process.getEnvMap(ally) catch null;
        if (child.env_map) |*m| {
            var i: usize = 0;
            while (i + 1 < envs.len) : (i += 2) {
                _ = m.put(envs[i], envs[i + 1]) catch {};
            }
        }
        try child.spawn();
        const out = try child.stdout.?.readToEndAlloc(ally, 1 << 20);
        const err = try child.stderr.?.readToEndAlloc(ally, 1 << 20);
        const term = try child.wait();
        const code: i32 = switch (term) {
            .Exited => |st| st,
            else => 2,
        };
        return .{ .code = code, .out = out, .err = err };
    }
    fn contains(hay: []const u8, needle: []const u8) bool {
        return std.mem.indexOf(u8, hay, needle) != null;
    }
};

test "storage: EXPAND_FROM_N two-hop" {
    const exe = "./zig-out/bin/geodec";
    // tiny+: 0->1, 0->2, 1->3
    const res = try E.run_with_env(&.{ exe, "RETURN EXPAND_FROM_N(0, 2) AS m ORDER BY m" }, &.{ "GEODE_ENGINE", "storage", "GEODE_TEST_GRAPH", "tiny_plus" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(E.contains(res.out, "{\"m\":3}"));
}

test "storage: EXPAND_FROM_LABELED one-hop" {
    const exe = "./zig-out/bin/geodec";
    const res = try E.run_with_env(&.{ exe, "RETURN EXPAND_FROM_LABELED(0, \"A\") AS m ORDER BY m" }, &.{ "GEODE_ENGINE", "storage", "GEODE_TEST_GRAPH", "tiny_labels" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(E.contains(res.out, "{\"m\":1}"));
}
