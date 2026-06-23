// Regression: a geode server that is IDLE-BUT-HAS-CONNECTIONS must not spin the
// FirstStreamScheduler cooperative workers.
//
// Companion to test_quic_idle_cpu.zig (which covers the ZERO-connection case
// fixed 2026-06-08). That fix made `FirstStreamScheduler.takeReady` park 1s when
// `contexts.items.len == 0`, but kept the 10ms `first_stream_scheduler_idle_sweep_ns`
// timeout whenever ANY context exists — to drive the missed-RX-wakeup sweep
// (REQ-QUIC-HC-100). The 10ms timeout was applied by EVERY one of the 512
// cooperative workers, so a handful of lingering idle connections made all 512
// workers wake 100x/s for a no-op scan: ~51k futex round-trips/s ≈ ~50% CPU on
// a build box, ~10 cores in production, all stolen from real edge-ingest/read
// work. (See docs/bugs/2026-06-23-idle-with-connections-firststream-busypoll.md.)
//
// This subprocess test boots a standalone server, opens a modest pool of QUIC
// connections, primes each with a single trivial query so the server holds a
// persistent first-stream context per connection, then leaves every connection
// completely idle and asserts server CPU over a 5s window stays well under a
// core. It FAILS before the fix (the cooperative pool spins at ~50%+) and PASSES
// after (idle workers park long; one designated sweeper keeps the 10ms cadence).
//
// Depends on a pre-built ./zig-out/bin/geode (SKIPs if missing); Linux-only.

const std = @import("std");
const builtin = @import("builtin");
const util = @import("proto_test_util.zig");

/// Number of idle connections to hold. The busy-poll cost scales with the
/// lingering contexts. The busy-poll has two compounding costs: (1) a fixed
/// ~51k futex round-trips/s from 512 workers waking every 10ms, and (2) growing
/// mutex contention as each 10ms sweep's O(contexts) scan lengthens the shared
/// critical section those 512 wakers funnel through. So the waste grows with the
/// number of lingering connections; 32 is enough to put the cost well above the
/// threshold on the unfixed build while staying cheap/reliable on a loaded CI
/// runner. Override with GEODE_IDLE_CPU_TEST_CONNS for manual scaling sweeps.
const default_idle_connection_count = 32;

fn idleConnectionCount() usize {
    if (std.c.getenv("GEODE_IDLE_CPU_TEST_CONNS")) |v| {
        return std.fmt.parseInt(usize, std.mem.span(v), 10) catch default_idle_connection_count;
    }
    return default_idle_connection_count;
}

fn nowMillis() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
    if (rc != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    const req = std.os.linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

/// Read (utime + stime) jiffies for `pid` from /proc/<pid>/stat (fields 14,15).
/// Robust to spaces in comm (field 2 is parenthesized) by scanning from the
/// closing ')'.
fn procCpuTicks(pid: i32) !u64 {
    var buf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "/proc/{d}/stat", .{pid});
    const fd = std.os.linux.open(@ptrCast(path.ptr), .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(fd)) < 0) return error.StatRead;
    const ifd: i32 = @intCast(fd);
    defer _ = std.os.linux.close(ifd);
    var fbuf: [8192]u8 = undefined;
    const n = std.os.linux.read(ifd, &fbuf, fbuf.len);
    const ns: isize = @bitCast(n);
    if (ns <= 0) return error.StatRead;
    const data = fbuf[0..@intCast(ns)];
    const rparen = std.mem.lastIndexOfScalar(u8, data, ')') orelse return error.StatParse;
    var it = std.mem.tokenizeScalar(u8, data[rparen + 1 ..], ' ');
    var idx: usize = 3; // next token is field 3 (state)
    var utime: ?u64 = null;
    var stime: ?u64 = null;
    while (it.next()) |tok| : (idx += 1) {
        if (idx == 14) utime = std.fmt.parseInt(u64, tok, 10) catch null;
        if (idx == 15) {
            stime = std.fmt.parseInt(u64, tok, 10) catch null;
            break;
        }
    }
    return (utime orelse return error.StatParse) + (stime orelse return error.StatParse);
}

test "idle server WITH lingering connections does not spin the cooperative scheduler" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (std.c.getenv("GEODE_SKIP_SUBPROC_CLUSTER") != null) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    // Pin the QUIC poll loop to a SINGLE worker so this test isolates the
    // FirstStreamScheduler cooperative-pool cost. With the default 16 release
    // poll workers, the unrelated 500us active-connection poll floor (~38% with
    // dozens of connections — a separate, known item, NOT this fix) would
    // dominate and mask the regression. With 1 poll worker the cooperative pool
    // is the only large idle consumer, so baseline (~36-47%) vs fixed (~5-7%)
    // separate cleanly. New-work latency is unaffected (the fix only changes the
    // idle wait cadence, not the wake path).
    const child_env = [_][]const u8{"GEODE_QUIC_POLL_WORKERS=1"};
    var server = util.spawnServerRandom(allocator, &child_env) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        return error.SkipZigTest;
    };
    defer server.deinit();

    const pid: i32 = server.child.id orelse return error.SkipZigTest;
    const idle_connection_count = idleConnectionCount();

    // Open `idle_connection_count` connections, HELLO + prime each with one
    // trivial query so the server installs a persistent first-stream owner
    // context per connection, then hold them ALL idle for the measurement.
    var clients: std.ArrayList(util.QuicProtoClient) = .empty;
    defer {
        for (clients.items) |*c| c.deinit();
        clients.deinit(allocator);
    }

    var primed: usize = 0;
    var i: usize = 0;
    while (i < idle_connection_count) : (i += 1) {
        var client = util.QuicProtoClient.connect(allocator, server.getAddr()) catch |err| {
            util.progress("connect {d} failed: {}", .{ i, err });
            continue;
        };
        var hello = client.hello(allocator, util.defaultUsername(), util.defaultPassword()) catch |err| {
            util.progress("hello {d} failed: {}", .{ i, err });
            client.deinit();
            continue;
        };
        hello.deinit(allocator);

        const params: std.ArrayList(@import("schema").Param) = .empty;
        var res = client.executeAndCollect(allocator, "RETURN 1 AS x", params, 100) catch |err| {
            util.progress("prime query {d} failed: {}", .{ i, err });
            client.deinit();
            continue;
        };
        res.deinit(allocator);

        clients.append(allocator, client) catch {
            client.deinit();
            continue;
        };
        primed += 1;
    }

    // Need a meaningful number of live contexts for the assertion to be
    // representative; if almost nothing connected, skip rather than false-pass.
    if (primed < idle_connection_count / 2) {
        util.progress("only primed {d}/{d} connections; skipping", .{ primed, idle_connection_count });
        return error.SkipZigTest;
    }
    util.progress("primed {d} idle connections; measuring server CPU...", .{primed});

    // Let the connections settle into the idle state, then measure CPU over a
    // window during which NO client sends anything. A correct scheduler parks
    // its idle workers; the buggy one wakes all 512 every 10ms.
    sleepMs(1500);
    const t0 = procCpuTicks(pid) catch return error.SkipZigTest;
    const window_ms: u64 = 5000;
    sleepMs(window_ms);
    const t1 = try procCpuTicks(pid);

    const clk_tck = std.c.sysconf(2); // _SC_CLK_TCK
    const hz: f64 = if (clk_tck > 0) @floatFromInt(clk_tck) else 100.0;
    const cpu_pct: f64 = @as(f64, @floatFromInt(t1 - t0)) / hz / (@as(f64, @floatFromInt(window_ms)) / 1000.0) * 100.0;

    // Threshold: with the poll loop pinned to 1 worker, the cooperative
    // FirstStreamScheduler is the only large idle consumer, so the buggy vs
    // fixed states separate by ~6-8x. Measured on a (busy) build box: BASELINE
    // 36-47% across 16-128 lingering connections (512 workers waking every 10ms,
    // each contending on the sweep mutex whose O(contexts) critical section grows
    // with connection count); FIXED a flat ~5-7% (one designated sweeper, the
    // rest park 1s and wake only on real work). 20% sits well clear of both:
    // robust to measurement noise on a loaded runner while still failing hard if
    // the per-worker 10ms sweep ever returns.
    const max_idle_pct: f64 = 20.0;
    if (cpu_pct > max_idle_pct) {
        std.debug.print(
            "FAIL: idle server with {d} connections CPU {d:.1}% exceeds {d:.1}% — cooperative scheduler is spinning\n",
            .{ primed, cpu_pct, max_idle_pct },
        );
        return error.IdleServerWithConnectionsBurnsCpu;
    }
    std.debug.print("idle server ({d} connections) CPU: {d:.1}% (< {d:.1}% OK)\n", .{ primed, cpu_pct, max_idle_pct });
}
