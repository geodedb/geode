// CANARY: REQ=REQ-SONNY-6300; FEATURE="Restore jobs"; ASPECT=TransportRegression; STATUS=TESTED; TEST=tests/test_sonny6300_restore_transport.zig; OWNER=storage; UPDATED=2026-11-11
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

test "SONNY-6300 actual TLS restore authorization, progress, resume and offline restart" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "TMPDIR" }) |name| {
        if (std.c.getenv(name)) |value| try env.put(name, std.mem.span(value));
    }
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(testing.allocator);
    try argv.appendSlice(testing.allocator, &.{ "python3", "tests/qualify_restore_transport.py", "--binary", "./zig-out/bin/geode" });
    if (std.c.getenv("GEODE_RESTORE_QUALIFICATION_PRIVATE_LOGS")) |path| {
        try argv.appendSlice(testing.allocator, &.{ "--private-logs", std.mem.span(path) });
    }
    const result = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = argv.items,
        .environ_map = &env,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(360), .clock = .awake } },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    const passed = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!passed) std.debug.print("actual restore transport qualification:\n{s}\n{s}\n", .{ result.stdout, result.stderr });
    try testing.expect(passed);
    inline for (.{ "async-acceptance-is-pending", "readonly-poll-refused", "cli-start-timeout-and-resume", "restart-restored-copy-retains-backup-data", "actual-cluster-restore-refused" }) |check| {
        try testing.expect(std.mem.indexOf(u8, result.stdout, check) != null);
    }
}
