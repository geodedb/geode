// SONNY-2719 regression: a CPU-starved engine is slowed, not killed by the
// accept-path wedge watchdog.
//
// The watchdog (src/server/main.zig metrics loop, src/server/acceptor_watchdog.zig)
// sampled the listener's UDP rx_queue every 5 s and exited the process with
// code 70 ("ACCEPTOR WEDGE") once the queue had stayed at or above a threshold
// for a deadline of wall-clock time. That cannot tell a wedged acceptor (it
// reads nothing off the socket) from a starved one (it reads, slower than
// datagrams arrive): on a CPU-starved host (a 1-CPU runner, a throttled
// container) the backlog stays high while the engine is draining it, and the
// watchdog killed a live server, dropping every connection.
//
// Here a real `geode serve` runs with the watchdog thresholds operators use
// on CI (docs/bugs/2026-07-28-...: 64 KiB, a short deadline). The test
// throttles it to 5% of a CPU by SIGSTOP/SIGCONT duty cycling (what cgroup
// cpu.max throttling does to a group) while UDP datagrams keep its listener
// backlogged. The server must still be running afterwards and answer a query.
// (A genuine wedge, no datagram drained for the deadline, still restarts:
// the unit tests in src/server/acceptor_watchdog.zig.)
//
// CANARY: REQ=REQ-SONNY-2719-STARVED-ACCEPTOR-SURVIVES; FEATURE="QUIC High-Concurrency Connection Admission"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2719_starved_acceptor_survives.zig; OWNER=transport; UPDATED=2026-11-13

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const geode_test_bin = @import("geode_test_bin");

const linux = std.os.linux;

fn monoMs() u64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

/// How long the server is starved and backlogged. Past the watchdog
/// deadline below by three 5 s metrics ticks.
const starve_ms: u64 = 30_000;

/// Datagrams to the listener, ~4000 a second, until `stop`.
const Sender = struct {
    port: u16,
    stop: std.atomic.Value(bool) = .init(false),
    sent: u64 = 0,

    fn run(self: *Sender) void {
        const fd_rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
        if (linux.errno(fd_rc) != .SUCCESS) return;
        const fd: i32 = @intCast(fd_rc);
        defer _ = linux.close(fd);
        const dest: linux.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, self.port),
            .addr = std.mem.nativeToBig(u32, 0x7f000001),
        };
        // Long-header-shaped bytes that are not a valid QUIC Initial: the
        // endpoint reads and discards each.
        var payload: [1200]u8 = undefined;
        for (&payload, 0..) |*b, i| b.* = @truncate(i *% 131 +% 7);
        payload[0] = 0xC3;
        while (!self.stop.load(.acquire)) {
            var i: usize = 0;
            while (i < 40) : (i += 1) {
                const rc = linux.sendto(fd, &payload, payload.len, 0, @ptrCast(&dest), @sizeOf(linux.sockaddr.in));
                if (linux.errno(rc) == .SUCCESS) self.sent += 1;
            }
            sleepMs(10);
        }
    }
};

/// 5 ms of CPU in every 100 ms for the server process, until `stop`.
const Throttle = struct {
    pid: linux.pid_t,
    stop: std.atomic.Value(bool) = .init(false),

    fn run(self: *Throttle) void {
        defer _ = linux.kill(self.pid, linux.SIG.CONT);
        while (!self.stop.load(.acquire)) {
            _ = linux.kill(self.pid, linux.SIG.CONT);
            sleepMs(5);
            if (self.stop.load(.acquire)) break;
            _ = linux.kill(self.pid, linux.SIG.STOP);
            sleepMs(95);
        }
    }
};

/// The exit status of an exited (not yet reaped) child, or null if it runs.
fn exitStatus(pid: linux.pid_t) ?i32 {
    var info = std.mem.zeroes(linux.siginfo_t);
    const rc = linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null);
    if (linux.errno(rc) != .SUCCESS) return -1;
    if (info.fields.common.first.piduid.pid == 0) return null;
    return info.fields.common.second.sigchld.status;
}

test "SONNY-2719: a CPU-starved server with a backlogged listener is slowed, not killed by the acceptor watchdog" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var data_dir_buf: [80]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&data_dir_buf, "/tmp/geode-sonny2719-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    var server = try util.spawnServer(
        allocator,
        &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir },
        &.{ "GEODE_ACCEPTOR_WATCHDOG_RX_BYTES=65536", "GEODE_ACCEPTOR_WATCHDOG_DEADLINE_MS=10000" },
    );
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30_000);
    const pid = server.child.id orelse return error.NoServerPid;

    var sender: Sender = .{ .port = port };
    var throttle: Throttle = .{ .pid = pid };
    const sender_thread = try std.Thread.spawn(.{}, Sender.run, .{&sender});
    const throttle_thread = try std.Thread.spawn(.{}, Throttle.run, .{&throttle});
    var joined = false;
    const stopLoad = struct {
        fn f(s: *Sender, t: *Throttle, st: std.Thread, tt: std.Thread) void {
            s.stop.store(true, .release);
            t.stop.store(true, .release);
            st.join();
            tt.join();
        }
    }.f;
    defer if (!joined) stopLoad(&sender, &throttle, sender_thread, throttle_thread);

    const until = monoMs() + starve_ms;
    var died: ?i32 = null;
    while (monoMs() < until) {
        if (exitStatus(pid)) |st| {
            died = st;
            break;
        }
        sleepMs(250);
    }
    stopLoad(&sender, &throttle, sender_thread, throttle_thread);
    joined = true;

    if (died) |st| {
        std.debug.print("the starved server exited with status {d} under a backlog it was draining ({d} datagrams sent): the acceptor watchdog took starvation for a wedge\n", .{ st, sender.sent });
        return error.StarvedServerKilled;
    }
    if (exitStatus(pid)) |st| {
        std.debug.print("the server exited with status {d} after the starvation ended\n", .{st});
        return error.StarvedServerKilled;
    }

    // Degraded, not dead: once it has CPU again it answers.
    try util.waitForServerReady(allocator, addr, 30_000);
    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer hello.deinit(allocator);
    try testing.expect(hello.success);
    var res = try client.executeAndCollect(allocator, "RETURN 1 AS x", util.emptyParams(), 10);
    defer res.deinit(allocator);
    try testing.expect(res.error_code == null);
    try testing.expectEqual(@as(usize, 1), res.rows.len);
}
