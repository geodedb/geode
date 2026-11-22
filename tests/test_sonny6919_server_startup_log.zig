//! SONNY-6919: a test server that never came up failed with a bare
//! ServerStartupTimeout after ten seconds (test_sonny6554 in main pipeline
//! 3098386881). spawnServer sent the child's output to /dev/null, so the
//! trace could not say whether geode had exited (a bind failure, say) or was
//! running without answering. The server's output now goes to a log file in
//! the test's scratch root, and a wait on a spawned server stops as soon as
//! the process has exited.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn monoMs() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

test "SONNY-6919: a server that exits during startup is reported at once, with its output" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Hold the port the server will be told to listen on, so its bind fails.
    const any = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const held = try any.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer held.close(io);
    const addr = try util.formatAddr(testing.allocator, held.address.getPort());
    defer testing.allocator.free(addr);

    var handle = try util.spawnServerWithAddr(testing.allocator, addr, null);
    defer handle.deinit();

    const timeout_ms: u64 = 60_000;
    const started = monoMs();
    try testing.expectError(error.ServerExitedDuringStartup, util.waitForSpawnedServer(&handle, timeout_ms));
    try testing.expect(monoMs() - started < @as(i64, @intCast(timeout_ms)));

    const log = try handle.readLogTail(testing.allocator, 64 * 1024);
    defer testing.allocator.free(log);
    if (std.mem.indexOf(u8, log, "BindFailed") == null) {
        std.debug.print("server log:\n{s}\n", .{log});
        return error.TestUnexpectedResult;
    }
}
