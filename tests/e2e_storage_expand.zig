const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run_with_env(args: []const []const u8, envs: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const allocator = std.testing.allocator;
    var child = Child.init(args, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = std.process.getEnvMap(allocator) catch null;
    if (child.env_map) |*m| {
        var i: usize = 0;
        while (i < envs.len) : (i += 2) {
            _ = m.put(envs[i], envs[i + 1]) catch {};
        }
    }
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 20);
    const err = try child.stderr.?.readToEndAlloc(allocator, 1 << 20);
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

test "storage: EXPAND_FROM smoke under storage engine" {
    const exe = "./zig-out/bin/geodec";
    const res = try run_with_env(&.{ exe, "RETURN EXPAND_FROM(0) AS n ORDER BY n" }, &.{ "GEODE_ENGINE", "storage", "GEODE_TEST_GRAPH", "tiny" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"type\":\"SCHEMA\""));
    try std.testing.expect(contains(res.out, "\"ordered\":true"));
    try std.testing.expect(contains(res.out, "\"order_keys\":[\"n\"]"));
    try std.testing.expect(contains(res.out, "{\"n\":1}"));
    try std.testing.expect(contains(res.out, "{\"n\":2}"));
}
