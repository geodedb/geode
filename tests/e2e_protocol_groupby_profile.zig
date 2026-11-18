const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

test "e2e: PROFILE returns payload for GROUP BY" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    util.testStart("PROFILE returns payload for GROUP BY");
    errdefer util.testFail();

    const allocator = testing.allocator;

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d}...", .{port});
    var server = util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr }, util.TestEnv.standard()) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer server.deinit();

    // Wait for server readiness
    util.waitForServerReady(allocator, addr, 10000) catch |err| {
        util.progress("Server readiness timeout: {}", .{err});
        util.testSkip();
        return;
    };

    util.progress("Running PROFILE GROUP BY query...", .{});
    var child = std.process.Child.init(
        &.{
            geode_test_bin.geode_exe,
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

    util.progress("Validating PROFILE payload...", .{});
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

    util.testPass();
}
