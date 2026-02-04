const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

test "e2e: PROFILE returns payload for GROUP BY" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:17690";

    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr }, null);
    defer server.deinit();

    var child = std.process.Child.init(
        &.{
            "./zig-out/bin/geode",
            "query",
            "PROFILE RETURN count(*) GROUP BY x",
            "--server",
            addr,
            "--insecure",
            "--user",
            util.defaultUsername(),
            "--password",
            util.defaultPassword(),
            "--format",
            "json",
        },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(out);
    _ = try child.stderr.?.readToEndAlloc(allocator, 1 << 18);
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, try child.wait());

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const profile_val = root.get("profile") orelse return error.MissingProfile;
    var profile_obj: std.json.ObjectMap = undefined;
    var nested: ?std.json.Parsed(std.json.Value) = null;
    defer if (nested) |*p| p.deinit();
    switch (profile_val.*) {
        .object => |obj| profile_obj = obj,
        .string => |s| {
            nested = try std.json.parseFromSlice(std.json.Value, allocator, s, .{});
            if (nested.?.value != .object) return error.BadProfile;
            profile_obj = nested.?.value.object;
        },
        else => return error.BadProfile,
    }
    try testing.expect(profile_obj.get("ops") != null);
}
