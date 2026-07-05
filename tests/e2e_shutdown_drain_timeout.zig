// Gap 0039 (data-ingest enterprise review, 2026-07-03): `geode serve`
// SIGTERM shutdown busy-spins forever draining abandoned QUIC connections.
//
// Live signature: SIGTERM lands, the data flush completes, then the process
// sits >= 10 minutes at ~1.75 cores with 2 threads spinning, the listener
// still accepting handshakes, and the periodic metrics line showing
// `active_streams` stuck with proto_idle_ms in the millions. The only way
// out was SIGKILL.
//
// Root cause: the graceful teardown has UNBOUNDED waits on connection
// handlers that never finish for an abandoned peer (client vanished without
// CONNECTION_CLOSE). The external thread-pool's `deinit` drains for
// `deinit_timeout_ns` (2 s) but then calls `joinAllWorkers()` — an unbounded
// join — so ONE stuck connection/acceptor task wedges the whole LIFO defer
// unwind in the serve loop forever (`waitForAllStreamsDrained` is likewise
// unbounded). Poll workers (registered earlier, torn down later) keep
// spinning, which is why the listener still answered handshakes.
//
// Contract under test (the fix):
//   1. On the shutdown signal the server stops accepting new connections
//      immediately (transport-level `shutting_down` gate).
//   2. The graceful connection drain is BOUNDED by
//      GEODE_SHUTDOWN_DRAIN_TIMEOUT_MS (default 30000). Connections still
//      alive at the deadline are force-closed
//      ("force-closing N stalled connections after drain timeout") and
//      shutdown proceeds.
//   3. The data flush / final WAL checkpoint stays UNBOUNDED (data safety)
//      and always runs before the teardown watchdog is armed.
//   4. The process EXITS with rc=0 within deadline + margin even with
//      abandoned client connections held open, and the store reopens clean.
//
// Scenarios:
//   * Scenario 1 (graceful window): drain timeout 2000 ms, two abandoned
//     peers (one authenticated + mid-frame, one handshake-only). Handlers
//     observe the shutdown flag and unwind inside the window; the drain
//     phase must engage ("[shutdown] draining") and the process must exit
//     rc=0 within the bound.
//   * Scenario 2 (deadline force-close): drain timeout 0 ms and a peer that
//     stops ACKing mid-response (EXECUTE a multi-hundred-KB result, never
//     read it) so its connection is provably still tracked when the
//     deadline check runs — the force-close marker must appear and the
//     process must still exit rc=0 within the bound.
//   * Scenario 3: the store reopens clean after both shutdown modes and an
//     idle server's SIGTERM also exits rc=0.
//
// Harness shape: single-node variant of the subprocess machinery used by
// tests/test_cluster_3node_subprocess.zig (spawn + piped stderr scrape),
// with proto_test_util's QuicProtoClient for the abandoned peers. An
// executable (not a `test`) for the same reason as
// e2e_quic_high_concurrency.zig: builtin.is_test enables verbose byte dumps
// inside the QUIC dependency.
//
// RED at HEAD (pre-fix, evidence in the gap log): exits without any drain
// phase — no "[shutdown] draining" / "force-closing ... after drain timeout"
// markers, GEODE_SHUTDOWN_DRAIN_TIMEOUT_MS unread — and when the teardown
// wedges on abandoned handlers the process never exits inside the deadline.

const std = @import("std");
const builtin = @import("builtin");
const util = @import("proto_test_util.zig");
const schema = @import("schema");

const linux = std.os.linux;
const posix = std.posix;

/// Wall-clock budget for "SIGTERM -> process gone". Composition:
/// bounded drain (<= 2 s in scenario 1, 0 s in scenario 2) + teardown
/// watchdog budget (2 s floor) + fresh-store flush + process teardown, with
/// CI margin. A wedged pre-fix server burns the whole budget and fails; the
/// fixed server exits in a fraction of it.
const exit_deadline_ms: i64 = 25_000;

fn nowMillis() i64 {
    var ts: posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    var req = linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    var rem: linux.timespec = undefined;
    _ = linux.nanosleep(&req, &rem);
}

fn setNonBlocking(file: std.Io.File) void {
    const fd = file.handle;
    const flags = linux.fcntl(fd, posix.F.GETFL, 0);
    if (@as(isize, @bitCast(flags)) < 0) return;
    const new_flags = flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
    _ = linux.fcntl(fd, posix.F.SETFL, new_flags);
}

/// Spawned `geode serve` child with PIPED stdio (proto_test_util's
/// spawnServer ignores child stdio, and this test must scrape the shutdown
/// transcript), mirroring tests/test_cluster_3node_subprocess.zig.
const ServeChild = struct {
    child: std.process.Child,
    reaped: bool = false,

    /// Best-effort teardown for failure paths: SIGKILL + reap. No-op once
    /// the test has already reaped the pid (avoids signaling a recycled pid).
    fn cleanup(self: *ServeChild) void {
        if (self.reaped) return;
        const pid = self.child.id orelse return;
        posix.kill(pid, .KILL) catch {};
        var status: u32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        self.reaped = true;
    }
};

fn spawnServeOn(
    aa: std.mem.Allocator,
    io_proc: std.Io,
    addr: []const u8,
    data_dir: []const u8,
    drain_timeout_ms: u64,
) !ServeChild {
    const args = try aa.alloc([]const u8, 7);
    args[0] = "./zig-out/bin/geode";
    args[1] = "serve";
    args[2] = "--listen";
    args[3] = addr;
    args[4] = "--data-dir";
    args[5] = data_dir;
    args[6] = "--log-level=info";

    // Minimal env, 3node-style: admin credentials the QuicProtoClient HELLO
    // uses, the gap-0039 drain knob, and PATH/HOME/LD_LIBRARY_PATH so
    // cert_gen can find openssl.
    const env_ptr = try aa.create(std.process.Environ.Map);
    env_ptr.* = std.process.Environ.Map.init(aa);
    try env_ptr.put("GEODE_ADMIN_USERNAME", util.DefaultAuth.username);
    try env_ptr.put("GEODE_ADMIN_PASSWORD", util.DefaultAuth.password);
    try env_ptr.put("GEODE_DEFAULT_PASSWORD", util.DefaultAuth.password);
    try env_ptr.put(
        "GEODE_SHUTDOWN_DRAIN_TIMEOUT_MS",
        try std.fmt.allocPrint(aa, "{d}", .{drain_timeout_ms}),
    );
    if (std.c.getenv("PATH")) |p| try env_ptr.put("PATH", std.mem.span(p));
    if (std.c.getenv("HOME")) |p| try env_ptr.put("HOME", std.mem.span(p));
    if (std.c.getenv("LD_LIBRARY_PATH")) |p| try env_ptr.put("LD_LIBRARY_PATH", std.mem.span(p));

    const child = try std.process.spawn(io_proc, .{
        .argv = args,
        .environ_map = env_ptr,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    const sc = ServeChild{ .child = child };
    if (sc.child.stderr) |f| setNonBlocking(f);
    if (sc.child.stdout) |f| setNonBlocking(f);
    return sc;
}

/// Non-blocking scrape of BOTH child pipes so a chatty server can never
/// block on a full pipe and the transcript is available for assertions.
fn drainOutput(sc: *ServeChild, capture: *std.ArrayList(u8), gpa: std.mem.Allocator) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var buf: [8192]u8 = undefined;
    inline for (.{ sc.child.stderr, sc.child.stdout }) |maybe_f| {
        if (maybe_f) |f| {
            while (true) {
                const n = f.readStreaming(io, &.{&buf}) catch break;
                if (n == 0) break;
                capture.appendSlice(gpa, buf[0..n]) catch break;
            }
        }
    }
}

fn waitUntilReady(
    sc: *ServeChild,
    addr: []const u8,
    capture: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) !void {
    const ready_deadline = nowMillis() + 120_000;
    while (nowMillis() < ready_deadline) {
        drainOutput(sc, capture, gpa);
        var probe = util.QuicProtoClient.connect(gpa, addr) catch {
            sleepMs(200);
            continue;
        };
        probe.deinit();
        return;
    }
    std.debug.print("FAIL: server never became ready.\n--- transcript ---\n{s}\n---\n", .{capture.items});
    return error.ServerStartupTimeout;
}

const WaitOutcome = struct {
    exited: bool,
    exit_code: u8 = 255,
    elapsed_ms: i64 = 0,
};

/// SIGTERM the child, then poll waitpid(WNOHANG) until it exits or the
/// deadline lapses, scraping output the whole time.
fn terminateAndAwait(
    sc: *ServeChild,
    deadline_ms: i64,
    capture: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) WaitOutcome {
    const pid = sc.child.id orelse return .{ .exited = false };
    const t0 = nowMillis();
    posix.kill(pid, .TERM) catch |err| {
        std.debug.print("FAIL: kill(SIGTERM) failed: {s}\n", .{@errorName(err)});
        return .{ .exited = false };
    };

    while (nowMillis() - t0 < deadline_ms) {
        drainOutput(sc, capture, gpa);
        var status: u32 = 0;
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        const rc_signed: isize = @bitCast(rc);
        if (rc_signed == pid) {
            sc.reaped = true;
            drainOutput(sc, capture, gpa);
            const exited = linux.W.IFEXITED(status);
            return .{
                .exited = true,
                .exit_code = if (exited) linux.W.EXITSTATUS(status) else 255,
                .elapsed_ms = nowMillis() - t0,
            };
        }
        if (rc_signed < 0) {
            // ECHILD etc. — gone with unknown status.
            sc.reaped = true;
            return .{ .exited = true, .exit_code = 255, .elapsed_ms = nowMillis() - t0 };
        }
        sleepMs(100);
    }
    return .{ .exited = false, .elapsed_ms = nowMillis() - t0 };
}

fn requireMarker(transcript: []const u8, marker: []const u8, what: []const u8) !void {
    if (std.mem.indexOf(u8, transcript, marker) == null) {
        std.debug.print(
            "FAIL: shutdown transcript missing {s} marker '{s}'.\n--- transcript ---\n{s}\n---\n",
            .{ what, marker, transcript },
        );
        return error.MarkerMissing;
    }
}

pub fn main() !void {
    if (comptime builtin.os.tag != .linux) {
        std.debug.print("SKIP: linux-only subprocess harness\n", .{});
        return;
    }
    const gpa = std.heap.smp_allocator;

    if (std.c.getenv("GEODE_SKIP_SUBPROC_CLUSTER") != null) {
        std.debug.print("SKIP: GEODE_SKIP_SUBPROC_CLUSTER set\n", .{});
        return;
    }
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io_fs, "./zig-out/bin/geode", .{}) catch {
        std.debug.print("SKIP: geode binary missing; run `zig build` first\n", .{});
        return;
    };

    // Arena for argv/env strings whose lifetime must span the children.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    // std.process.spawn needs an Io with a real allocator (the process-global
    // single-threaded Io ships with .allocator = .failing) — same workaround
    // as the 3node subprocess test.
    var spawn_threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer spawn_threaded.deinit();
    const io_proc = spawn_threaded.io();

    const port = try util.getRandomPort();
    const addr = try std.fmt.allocPrint(aa, "127.0.0.1:{d}", .{port});
    const data_dir = try std.fmt.allocPrint(aa, "/tmp/geode-shutdown-drain-{d}-{d}", .{ nowMillis(), port });
    std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};

    // ═════ Scenario 1: graceful bounded drain (timeout 2000 ms) ═════
    var capture1: std.ArrayList(u8) = .empty;
    defer capture1.deinit(gpa);

    std.debug.print("[scenario1] spawning server on {s} data_dir={s} drain=2000ms\n", .{ addr, data_dir });
    var sc1 = try spawnServeOn(aa, io_proc, addr, data_dir, 2000);
    defer sc1.cleanup();
    try waitUntilReady(&sc1, addr, &capture1, gpa);

    // Client A: full handshake + HELLO auth, then a PARTIAL frame (length
    // prefix promising 64 bytes, only 8 delivered) so the server-side proto
    // reader is parked mid-frame — then the client goes silent forever.
    var client_a = try util.QuicProtoClient.connect(gpa, addr);
    var hello_a = try client_a.hello(gpa, util.defaultUsername(), util.defaultPassword());
    defer hello_a.deinit(gpa);
    if (!hello_a.success) {
        std.debug.print("FAIL: HELLO rejected: {s}\n", .{hello_a.error_message});
        return error.HelloFailed;
    }
    {
        var partial: [12]u8 = undefined;
        std.mem.writeInt(u32, partial[0..4], 64, .big);
        @memset(partial[4..], 0xAB);
        try client_a.stream.writeAll(&partial);
        try client_a.client.poll(0);
    }

    // Client B: QUIC handshake only.
    var client_b = try util.QuicProtoClient.connect(gpa, addr);
    _ = &client_b;

    // ABANDON both: no close, no deinit, no further polls.
    sleepMs(500); // let the server admit the connections / register readers
    drainOutput(&sc1, &capture1, gpa);

    const outcome1 = terminateAndAwait(&sc1, exit_deadline_ms, &capture1, gpa);
    if (!outcome1.exited) {
        std.debug.print(
            "FAIL: server did not exit within {d}ms of SIGTERM with abandoned connections open (gap 0039 wedge).\n--- transcript ---\n{s}\n---\n",
            .{ exit_deadline_ms, capture1.items },
        );
        sc1.cleanup();
        return error.ShutdownWedged;
    }
    std.debug.print("[scenario1] exited rc={d} in {d}ms\n", .{ outcome1.exit_code, outcome1.elapsed_ms });
    if (outcome1.exit_code != 0) {
        std.debug.print("--- transcript ---\n{s}\n---\n", .{capture1.items});
        return error.NonZeroExit;
    }
    // Bounded-drain phase engaged and the flush ran on the shutdown path.
    try requireMarker(capture1.items, "[shutdown] draining", "bounded-drain");
    try requireMarker(capture1.items, "[shutdown] data flush complete", "data-flush");

    // ═════ Scenario 2: deadline force-close (timeout 0 ms) ═════
    // A peer that stops ACKing mid-response: EXECUTE a result far larger
    // than the congestion/flow-control credit a silent peer grants, never
    // read a byte of it. The server's response writeAll stalls (bounded
    // 60 s writer budget), so the connection is still tracked when the
    // 0 ms drain deadline expires — force-close must fire and be logged.
    var capture2: std.ArrayList(u8) = .empty;
    defer capture2.deinit(gpa);

    std.debug.print("[scenario2] spawning server (drain=0ms) for force-close path\n", .{});
    var sc2 = try spawnServeOn(aa, io_proc, addr, data_dir, 0);
    defer sc2.cleanup();
    try waitUntilReady(&sc2, addr, &capture2, gpa);

    var client_c = try util.QuicProtoClient.connect(gpa, addr);
    var hello_c = try client_c.hello(gpa, util.defaultUsername(), util.defaultPassword());
    defer hello_c.deinit(gpa);
    if (!hello_c.success) {
        std.debug.print("FAIL: scenario2 HELLO rejected: {s}\n", .{hello_c.error_message});
        return error.HelloFailed;
    }
    {
        const exec_req = schema.ExecuteRequest{
            .session_id = client_c.session_id,
            .query = "UNWIND range(1, 200000) AS n RETURN n",
            .params = std.ArrayList(schema.Param).empty,
        };
        try client_c.writeMessage(.{ .execute = exec_req });
    }
    // Never read the response; never poll again. Give the server time to
    // start streaming and hit the silent peer's credit wall.
    sleepMs(1500);
    drainOutput(&sc2, &capture2, gpa);

    const outcome2 = terminateAndAwait(&sc2, exit_deadline_ms, &capture2, gpa);
    if (!outcome2.exited) {
        std.debug.print(
            "FAIL: server did not exit within {d}ms of SIGTERM with a mid-response abandoned peer (gap 0039 wedge).\n--- transcript ---\n{s}\n---\n",
            .{ exit_deadline_ms, capture2.items },
        );
        sc2.cleanup();
        return error.ShutdownWedged;
    }
    std.debug.print("[scenario2] exited rc={d} in {d}ms\n", .{ outcome2.exit_code, outcome2.elapsed_ms });
    if (outcome2.exit_code != 0) {
        std.debug.print("--- transcript ---\n{s}\n---\n", .{capture2.items});
        return error.NonZeroExit;
    }
    try requireMarker(capture2.items, "[shutdown] draining", "bounded-drain");
    try requireMarker(capture2.items, "force-closing", "force-close");
    try requireMarker(capture2.items, "after drain timeout", "force-close-deadline");
    try requireMarker(capture2.items, "[shutdown] data flush complete", "data-flush");

    // ═════ Scenario 3: store reopens clean; idle SIGTERM exits rc=0 ═════
    var capture3: std.ArrayList(u8) = .empty;
    defer capture3.deinit(gpa);

    std.debug.print("[scenario3] reopening store\n", .{});
    var sc3 = try spawnServeOn(aa, io_proc, addr, data_dir, 2000);
    defer sc3.cleanup();
    try waitUntilReady(&sc3, addr, &capture3, gpa);

    // Prove the reopened store serves authenticated traffic (clean recovery),
    // and this time CLOSE the client properly.
    {
        var probe = try util.QuicProtoClient.connect(gpa, addr);
        var probe_hello = try probe.hello(gpa, util.defaultUsername(), util.defaultPassword());
        defer probe_hello.deinit(gpa);
        if (!probe_hello.success) {
            std.debug.print("FAIL: HELLO after reopen rejected: {s}\n", .{probe_hello.error_message});
            return error.ReopenHelloFailed;
        }
        probe.deinit();
    }

    const outcome3 = terminateAndAwait(&sc3, exit_deadline_ms, &capture3, gpa);
    if (!outcome3.exited or outcome3.exit_code != 0) {
        std.debug.print(
            "FAIL: reopened server SIGTERM exit failed (exited={} rc={d}).\n--- transcript ---\n{s}\n---\n",
            .{ outcome3.exited, outcome3.exit_code, capture3.items },
        );
        sc3.cleanup();
        return error.ReopenShutdownFailed;
    }
    std.debug.print("[scenario3] reopened server exited rc=0 in {d}ms\n", .{outcome3.elapsed_ms});

    std.debug.print("PASS: bounded SIGTERM drain (gap 0039)\n", .{});
}
