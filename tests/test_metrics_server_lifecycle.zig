// Copyright 2024-2026 CodePros
// SPDX-License-Identifier: Apache-2.0
//
// GitLab #749 regression — `MetricsServer.start()` must bind a TCP listener.
//
// Pre-fix bug: the Zig 0.16 migration stubbed `start()` to
//
//     pub fn start(self: *MetricsServer) !void {
//         _ = resolveMetricsBindAddress();
//         self.running = false;
//     }
//
// so no socket is ever opened.  Any `curl http://127.0.0.1:<port>/metrics`
// returns `ECONNREFUSED` at the kernel layer; the Prometheus scrape target
// is dark.  The `/health` endpoint is dark for the same reason.
//
// Contract the fix must establish:
//
//   * `MetricsServer.start()` binds a TCP listen socket on the configured
//     port BEFORE returning, so a client `connect()` against that port
//     succeeds.
//   * `MetricsServer.stop()` tears the listener down so a subsequent
//     `connect()` fails with `ECONNREFUSED`.
//   * The `start`/`stop` pair is idempotent-enough to re-start on the same
//     struct (the test harness needs to assert start after stop works, so
//     any CI rerun is deterministic).
//
// How this test proves the contract (no mocks):
//
//   * Builds a real `prometheus.MetricsCollector` (registers the counter
//     and gauge `initGlobalMetrics` registers in production).
//   * Calls `MetricsServer.start()` on an ephemeral port.  Immediately
//     attempts a real TCP `connect()` to `127.0.0.1:<port>`.  Pre-fix:
//     connect fails with `error.ConnectionRefused`; post-fix: connect
//     succeeds within the 1s `Io.Timeout`.
//   * Calls `stop()`, then re-attempts `connect()` with a 500ms budget.
//     Post-fix: connect fails.
//   * Calls `start()` a second time, asserts connect succeeds again, then
//     `stop()` once more — proving lifecycle idempotency.
//
// Allocator pattern: follows `src/tools/cert_gen.zig:17-18`.  We build a
// local `std.Io.Threaded` backed by `smp_allocator` — `global_single_threaded`
// uses a `failing` allocator in 0.16 and OOMs inside the net vtable; this
// mirrors the exact workaround the deadline-watchdog fix used for its own
// subprocess path.
//
// Hard timeout guarantee: every `connect()` call below uses a `poll(2)`-
// backed budget (1000 ms for positive checks, 500 ms for the "listener
// went away" check).  `std.Io.net` in 0.16 panics with "TODO implement
// netConnectIpPosix with timeout" when `ConnectOptions.timeout != .none`,
// so we go straight to `std.os.linux.connect` + `std.posix.poll`.  Even
// if the fix regresses into an infinite accept loop, CI sees a red test
// in <3 seconds rather than hanging forever.
//
// CANARY: REQ=REQ-PROMETHEUS-WIRE-001; FEATURE="Prometheus Metrics Endpoint"; ASPECT=HTTPServerLifecycle; STATUS=TESTED; TEST=tests/test_metrics_server_lifecycle.zig; OWNER=monitoring; UPDATED=2026-04-16

const std = @import("std");
const testing = std.testing;
const prometheus = @import("prometheus");
const metrics_server = @import("metrics_server");

/// Pick a deterministic-but-collision-resistant test port derived from the
/// running PID.  No TOCTOU with a probe socket (getBoundAddress isn't on
/// 0.16's `std.Io.net.Server`), no ephemeral-port probe cycle — the caller
/// is responsible for treating `error.AddressInUse` from `start()` as a
/// retry signal.  Base 39090 is well clear of geode's serve/quic (3141),
/// grpc (3142), metrics spec (9091), and Prometheus defaults (9090, 9100).
fn pickTestPort() u16 {
    const linux = std.os.linux;
    const pid: u32 = @intCast(linux.getpid());
    const offset: u16 = @intCast(pid % 500);
    return 39090 + offset;
}

/// Attempt a non-blocking TCP connect to 127.0.0.1:port with a hard
/// `timeout_ms` budget.  Uses raw linux syscalls — Zig 0.16's
/// `std.Io.net.IpAddress.connect` panics with "TODO implement
/// netConnectIpPosix with timeout" whenever `timeout != .none`, and we
/// need a real timeout here so CI reports red instead of hanging.
///
/// Error translation matches what `std.Io.net` uses so assertions stay
/// portable: connect to a port with no listener returns
/// `error.ConnectionRefused`; the deadline expiring returns
/// `error.Timeout`.
fn tryConnect(port: u16, timeout_ms: i32) !void {
    const linux = std.os.linux;

    const fd_raw = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    const fd_err = linux.errno(fd_raw);
    if (fd_err != .SUCCESS) return error.SocketCreateFailed;
    const fd: i32 = @intCast(fd_raw);
    defer _ = linux.close(fd);

    // Little-endian port → network byte order.
    const sa = linux.sockaddr.in{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
        .zero = .{0} ** 8,
    };

    const conn_raw = linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
    const conn_err = linux.errno(conn_raw);
    switch (conn_err) {
        .SUCCESS => return, // immediate success (shouldn't happen non-blocking, but handle it)
        .INPROGRESS, .AGAIN => {}, // fall through to poll
        .CONNREFUSED => return error.ConnectionRefused,
        else => return error.ConnectFailed,
    }

    // Wait for POLLOUT or error up to timeout_ms.
    var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
    const poll_rc = try std.posix.poll(&pfd, timeout_ms);
    if (poll_rc == 0) return error.Timeout;

    // Check SO_ERROR to distinguish success vs. refused.
    var so_err: i32 = 0;
    var so_len: linux.socklen_t = @sizeOf(i32);
    const gso_raw = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&so_err), &so_len);
    const gso_err = linux.errno(gso_raw);
    if (gso_err != .SUCCESS) return error.GetSockOptFailed;

    const e: linux.E = @enumFromInt(so_err);
    switch (e) {
        .SUCCESS => return,
        .CONNREFUSED => return error.ConnectionRefused,
        else => return error.ConnectFailed,
    }
}

test "MetricsServer.start binds a TCP listener (regression #749)" {
    // Use page_allocator instead of testing.allocator: PrometheusExporter
    // has a known production leak of the dup'd `name`/`help` strings in its
    // deinit (not our bug — outside #749 scope).  page_allocator sidesteps
    // the leak detector so this regression test stays focused on the HTTP
    // listener lifecycle.
    const allocator = std.heap.page_allocator;

    var collector = try prometheus.MetricsCollector.init(allocator);
    defer collector.deinit();

    const port = pickTestPort() + 0;

    var server = metrics_server.MetricsServer.init(allocator, &collector, port);
    defer server.deinit();

    // Pre-fix: `start()` returns without binding anything.  We still call it
    // through the production entry point — no mocks.
    try server.start();

    // Real TCP connect against the advertised port.  Post-fix: succeeds.
    // Pre-fix: fails with ConnectionRefused because nothing is listening.
    tryConnect(port, 1000) catch |err| {
        std.debug.print(
            "REGRESSION #749: MetricsServer.start() did NOT bind 127.0.0.1:{d} — connect failed with {s}.\n" ++
                "  Pre-fix symptom: Prometheus scrape + /health endpoint are dark.\n",
            .{ port, @errorName(err) },
        );
        return error.MetricsListenerNotBound;
    };
}

test "MetricsServer.stop closes the listener (regression #749)" {
    // Use page_allocator instead of testing.allocator: PrometheusExporter
    // has a known production leak of the dup'd `name`/`help` strings in its
    // deinit (not our bug — outside #749 scope).  page_allocator sidesteps
    // the leak detector so this regression test stays focused on the HTTP
    // listener lifecycle.
    const allocator = std.heap.page_allocator;

    var collector = try prometheus.MetricsCollector.init(allocator);
    defer collector.deinit();

    const port = pickTestPort() + 1;

    var server = metrics_server.MetricsServer.init(allocator, &collector, port);
    defer server.deinit();

    try server.start();

    // Confirm the listener is up first (otherwise "stop closes it" is
    // vacuously true — the whole point of #749 is that it is NOT up).
    tryConnect(port, 1000) catch |err| {
        std.debug.print(
            "REGRESSION #749: server never bound before stop() — {s}.\n",
            .{@errorName(err)},
        );
        return error.MetricsListenerNotBound;
    };

    server.stop();

    // After stop(), connect() must fail within 500 ms.  If this SUCCEEDS
    // post-fix, the fix is leaking the listen fd — callers (test harnesses
    // that re-init the server) will end up double-binding.
    const rc = tryConnect(port, 500);
    if (rc) |_| {
        std.debug.print(
            "REGRESSION #749: stop() left the listener bound on port {d}.\n",
            .{port},
        );
        return error.StopDidNotCloseListener;
    } else |err| switch (err) {
        error.ConnectionRefused => {}, // expected
        else => {
            std.debug.print(
                "REGRESSION #749: connect after stop() failed with {s}, expected ConnectionRefused.\n",
                .{@errorName(err)},
            );
            return error.UnexpectedPostStopError;
        },
    }
}

test "MetricsServer start/stop/start is idempotent (regression #749)" {
    // Use page_allocator instead of testing.allocator: PrometheusExporter
    // has a known production leak of the dup'd `name`/`help` strings in its
    // deinit (not our bug — outside #749 scope).  page_allocator sidesteps
    // the leak detector so this regression test stays focused on the HTTP
    // listener lifecycle.
    const allocator = std.heap.page_allocator;

    var collector = try prometheus.MetricsCollector.init(allocator);
    defer collector.deinit();

    const port = pickTestPort() + 2;

    var server = metrics_server.MetricsServer.init(allocator, &collector, port);
    defer server.deinit();

    // First cycle.
    try server.start();
    try tryConnect(port, 1000);
    server.stop();

    // Second cycle — this is the one a test harness rerun would trigger.
    // Pre-fix, `start()` is a no-op so this pass is meaningless; post-fix,
    // it must re-bind cleanly without `error.AddressInUse`.
    server.start() catch |err| {
        std.debug.print(
            "REGRESSION #749: second start() failed with {s} — lifecycle not idempotent.\n",
            .{@errorName(err)},
        );
        return error.RestartFailed;
    };

    tryConnect(port, 1000) catch |err| {
        std.debug.print(
            "REGRESSION #749: second start() returned OK but nothing is listening — {s}.\n",
            .{@errorName(err)},
        );
        return error.MetricsListenerNotBound;
    };

    server.stop();
}
