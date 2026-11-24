//! SONNY-6956: `waitForServerReady` gave a server the caller's budget, ten
//! seconds at 35 call sites, and a loaded CI runner starved a healthy
//! server's startup past it (test_sonny6587_profile_point_write_seek in main
//! pipeline 3106953387: ServerStartupTimeout after 10 s). How long a live
//! server may take to answer is a property of the runner, not of the test,
//! so the wait gives every server at least SPAWN_STARTUP_TIMEOUT_MS, the
//! budget spawnServerRandom already gives one (SONNY-6922). Starve a server
//! for real: stop the process for 12 seconds, longer than the 10 s asked
//! for, then let it continue.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const requested_ms: u64 = 10_000;
const stall_ms: u64 = 12_000;

fn resumeAfterStall(pid: std.posix.pid_t) void {
    var ts: std.posix.timespec = .{ .sec = @intCast(stall_ms / 1000), .nsec = 0 };
    _ = std.os.linux.nanosleep(&ts, null);
    _ = std.os.linux.kill(pid, std.os.linux.SIG.CONT);
}

test "SONNY-6956: waitForServerReady awaits a live server stalled past the budget its caller asked for" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    comptime std.debug.assert(stall_ms > requested_ms);
    comptime std.debug.assert(util.SPAWN_STARTUP_TIMEOUT_MS > stall_ms);

    const port = try util.getRandomPort();
    const addr = try util.formatAddr(testing.allocator, port);

    var handle = util.spawnServerWithAddr(testing.allocator, addr, null) catch |err| {
        testing.allocator.free(addr);
        return err;
    };
    // The handle owns the address from here (deinit frees it).
    handle.port = port;
    handle.addr = addr;
    defer handle.deinit();
    const pid = handle.child.id orelse return error.NoChildPid;
    _ = std.os.linux.kill(pid, std.os.linux.SIG.STOP);
    const resumer = try std.Thread.spawn(.{}, resumeAfterStall, .{pid});
    defer resumer.join();

    util.waitForServerReady(testing.allocator, addr, requested_ms) catch |err| {
        handle.reportStartupFailure(err);
        return err;
    };
}
