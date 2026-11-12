// Regression: an IDLE geode server (0 connections) must not burn many CPU cores.
//
// A 0-connection geode was observed pinning ~810% CPU (≈8 cores) on a deployed
// node. Per-thread profiling (2026-06-08) found FOUR independent idle spinners,
// fixed geode-side (see docs/bugs/2026-06-08-idle-node-810pct-cpu-poll-and-pool-spin.md):
//   1. QUIC poll workers (16 in release): pollLoop did poll(0)+500us-sleep
//      regardless of connection count; each poll(0) 0xAA-fills a 256 KB recv
//      buffer under ReleaseSafe. Fix: park `idle_poll_empty_park_ns` (250ms)
//      when active_connection_count==0; keep the 500us floor when live.
//   2. ~800 thread_pool wrapper workers parked at the 10ms GAP-0807 default →
//      ~80k futex/s. Fix: raise the wrapper idle_park_after_ns to 500ms.
//   3. 512 FirstStreamScheduler cooperative workers swept every 10ms even with
//      0 contexts. Fix: park 1s when there are no contexts.
//   4. The geode timeseries pool (4 workers) used the upstream ext 250us idle
//      park. Fix: set its idle_park_after_ns to 500ms.
//
// Residual (NOT yet fixed here): graph_storage's per-graph owned pool (4 workers,
// `default_owned_pool_max_threads`) also inherits the ext thread_pool 250us idle
// park. That is a vendored lib whose root fix is the ext thread_pool default /
// a graph_storage idle_park — tracked as a downstream follow-up. It contributes
// a small, load-sensitive floor (~5% on a quiet box, more under heavy contention).
//
// This subprocess test boots a standalone server, leaves it completely idle (no
// client connects), and asserts CPU over a 5s window is well under a core. The
// threshold cleanly separates the FIXED state (a small fraction of a core, even
// with the graph_storage residual + CI load noise) from ANY regression of the
// four spinners above (each is >100% on its own when broken). FAILS before the
// fix (670% on the ReleaseSafe binary / ~100% on the 1-worker debug build).
// Spawns the geode this build emitted (SONNY-2697); Linux-only.

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const builtin = @import("builtin");
const test_ports = @import("test_ports.zig");

const BINARY_PATH = geode_test_bin.geode_exe;

fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

fn nowMillis() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

/// Read (utime + stime) jiffies for `pid` from /proc/<pid>/stat (fields 14,15).
/// Robust to spaces in comm (field 2 is parenthesized) by scanning from the
/// closing ')'.
fn procCpuTicks(io: std.Io, pid: i32) !u64 {
    var buf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/proc/{d}/stat", .{pid});
    var fbuf: [8192]u8 = undefined;
    const n = std.Io.Dir.cwd().readFile(io, path, &fbuf) catch return error.StatRead;
    const data = fbuf[0..n.len];
    const rparen = std.mem.lastIndexOfScalar(u8, data, ')') orelse return error.StatParse;
    // After ')' come space-separated fields starting at field 3 (state).
    var it = std.mem.tokenizeScalar(u8, data[rparen + 1 ..], ' ');
    var idx: usize = 3; // next token is field 3
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

fn buildChildEnv(aa: std.mem.Allocator) !*std.process.Environ.Map {
    const env_ptr = try aa.create(std.process.Environ.Map);
    env_ptr.* = std.process.Environ.Map.init(aa);
    if (posixGetenv("PATH")) |p| try env_ptr.put("PATH", p);
    if (posixGetenv("HOME")) |p| try env_ptr.put("HOME", p);
    if (posixGetenv("LD_LIBRARY_PATH")) |p| try env_ptr.put("LD_LIBRARY_PATH", p);
    try env_ptr.put("GEODE_ADMIN_PASSWORD", "Idle Cpu Test Admin Passphrase"); // gitleaks:allow — test fixture password
    return env_ptr;
}

test "idle server (0 connections) does not burn CPU in the poll loop" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (posixGetenv("GEODE_SKIP_SUBPROC_CLUSTER") != null) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var spawn_threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer spawn_threaded.deinit();
    const io = spawn_threaded.io();

    std.Io.Dir.cwd().access(io, BINARY_PATH, .{}) catch return error.SkipZigTest;

    const data_dir = try std.fmt.allocPrint(aa, "/tmp/geode-idlecpu-{d}", .{nowMillis()});
    std.Io.Dir.cwd().createDirPath(io, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    // SONNY-6301: free ports, not constants: another run on the host held them.
    const listen = try std.fmt.allocPrint(aa, "127.0.0.1:{d}", .{try test_ports.freeUdpPort()});
    const args = [_][]const u8{
        BINARY_PATH,  "serve",  "--listen",    listen,
        "--data-dir", data_dir, "--log-level", "error",
    };
    var child = try std.process.spawn(io, .{
        .argv = &args,
        .environ_map = try buildChildEnv(aa),
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var reaped = false;
    defer if (!reaped) {
        child.kill(io);
        reaped = true;
    };
    const pid: i32 = child.id orelse return error.SkipZigTest;

    // Wait for the server to be listening (drain stdout/stderr so the pipe never
    // fills, and look for the ready banner). Give up after 20s.
    if (comptime builtin.os.tag == .linux) {
        inline for ([_]?std.Io.File{ child.stdout, child.stderr }) |maybe_f| {
            if (maybe_f) |f| {
                const fd = f.handle;
                const flags = std.os.linux.fcntl(fd, std.posix.F.GETFL, 0);
                _ = std.os.linux.fcntl(fd, std.posix.F.SETFL, flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
            }
        }
    }
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(gpa);
    var buf: [4096]u8 = undefined;
    const deadline = nowMillis() + 20_000;
    while (nowMillis() < deadline) {
        inline for ([_]?std.Io.File{ child.stdout, child.stderr }) |maybe_f| {
            if (maybe_f) |f| {
                const got = f.readStreaming(io, &.{&buf}) catch 0;
                if (got > 0) captured.appendSlice(gpa, buf[0..got]) catch {};
            }
        }
        if (std.mem.indexOf(u8, captured.items, "server ready") != null) break;
        sleepMs(50);
    }
    if (std.mem.indexOf(u8, captured.items, "server ready") == null) return error.ServerNeverReady;

    // Let it settle, then measure CPU over a window with ZERO connections.
    sleepMs(1000);
    const t0 = procCpuTicks(io, pid) catch return error.SkipZigTest; // /proc gone → skip
    const window_ms: u64 = 5000;
    sleepMs(window_ms);
    const t1 = try procCpuTicks(io, pid);

    child.kill(io);
    reaped = true;

    // _SC_CLK_TCK = 2 on Linux/glibc (Zig's std.c._SC.linux enum only exposes
    // PAGESIZE). This test is Linux-only (skips above otherwise), so the literal
    // is safe. Falls back to USER_HZ=100 if sysconf returns <= 0.
    const clk_tck = std.c.sysconf(2);
    const hz: f64 = if (clk_tck > 0) @floatFromInt(clk_tck) else 100.0;
    const cpu_pct: f64 = @as(f64, @floatFromInt(t1 - t0)) / hz / (@as(f64, @floatFromInt(window_ms)) / 1000.0) * 100.0;

    // Threshold: an idle server should use well under one core. The four fixed
    // spinners were 670%/224%/etc. when broken — each >100% on its own — so 50%
    // robustly catches ANY regression while tolerating (a) the documented
    // graph_storage owned-pool residual and (b) measurement noise on a loaded CI
    // runner (futex round-trips cost more under contention). Observed post-fix:
    // ~23% on a load-9 box. A regression of any single spinner blows past 100%.
    const max_idle_pct: f64 = 50.0;
    if (cpu_pct > max_idle_pct) {
        std.debug.print("FAIL: idle server CPU {d:.1}% exceeds {d:.1}% — poll loop is spinning when idle\n", .{ cpu_pct, max_idle_pct });
        return error.IdleServerBurnsCpu;
    }
    std.debug.print("idle server CPU: {d:.1}% (< {d:.1}% OK)\n", .{ cpu_pct, max_idle_pct });
}
