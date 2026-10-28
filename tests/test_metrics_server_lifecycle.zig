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
// so we go straight to `std.c.connect` + `std.posix.poll`.  Even
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
    const pid: u32 = @intCast(std.c.getpid());
    const offset: u16 = @intCast(pid % 500);
    return 39090 + offset;
}

fn tcpSocket(nonblocking: bool) !std.posix.fd_t {
    const fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
    if (fd < 0) return error.SocketCreateFailed;
    errdefer _ = std.c.close(fd);
    if (std.c.fcntl(fd, std.posix.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC)) < 0) return error.FcntlFailed;
    if (nonblocking) {
        const flags = std.c.fcntl(fd, std.posix.F.GETFL);
        if (flags < 0) return error.FcntlFailed;
        const nonblock = @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true }));
        if (std.c.fcntl(fd, std.posix.F.SETFL, flags | nonblock) < 0) return error.FcntlFailed;
    }
    return fd;
}

/// Attempt a non-blocking TCP connect to 127.0.0.1:port with a hard
/// `timeout_ms` budget.  Uses POSIX libc calls — Zig 0.16's
/// `std.Io.net.IpAddress.connect` panics with "TODO implement
/// netConnectIpPosix with timeout" whenever `timeout != .none`, and we
/// need a real timeout here so CI reports red instead of hanging.
///
/// Error translation matches what `std.Io.net` uses so assertions stay
/// portable: connect to a port with no listener returns
/// `error.ConnectionRefused`; the deadline expiring returns
/// `error.Timeout`.
fn tryConnect(port: u16, timeout_ms: i32) !void {
    const fd = try tcpSocket(true);
    defer _ = std.c.close(fd);

    // Little-endian port → network byte order.
    const sa = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
        .zero = .{0} ** 8,
    };

    const conn_raw = std.c.connect(fd, @ptrCast(&sa), @sizeOf(std.posix.sockaddr.in));
    const conn_err = std.posix.errno(conn_raw);
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
    var so_len: std.posix.socklen_t = @sizeOf(i32);
    const gso_raw = std.c.getsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.ERROR, @ptrCast(&so_err), &so_len);
    const gso_err = std.posix.errno(gso_raw);
    if (gso_err != .SUCCESS) return error.GetSockOptFailed;

    const e: std.posix.E = @enumFromInt(so_err);
    switch (e) {
        .SUCCESS => return,
        .CONNREFUSED => return error.ConnectionRefused,
        else => return error.ConnectFailed,
    }
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

fn writeAll(fd: i32, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        const signed = rc;
        if (signed < 0) return error.WriteFailed;
        if (signed == 0) return error.WriteFailed;
        offset += @intCast(signed);
    }
}

fn httpResponseComplete(data: []const u8) bool {
    const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return false;
    const headers = data[0..header_end];
    const key = "Content-Length:";
    const key_start = std.mem.indexOf(u8, headers, key) orelse return false;
    var idx = key_start + key.len;
    while (idx < headers.len and (headers[idx] == ' ' or headers[idx] == '\t')) : (idx += 1) {}
    const value_start = idx;
    while (idx < headers.len and std.ascii.isDigit(headers[idx])) : (idx += 1) {}
    if (idx == value_start) return false;
    const content_len = std.fmt.parseUnsigned(usize, headers[value_start..idx], 10) catch return false;
    return data.len >= header_end + 4 + content_len;
}

/// Send a HEADERLESS `GET <path> HTTP/1.0` whose terminating empty line
/// arrives in a SEPARATE TCP segment — exactly what `bash`'s `/dev/tcp`
/// probe puts on the wire (verified against a live server), and what any
/// proxy, slow link or k8s HTTP probe may produce. TCP gives no message
/// framing, so this is legal HTTP a server must handle.
///
/// This is the shape that exposed the request-line lifetime bug: the second
/// segment is not yet buffered when the header drain runs, so the drain
/// refills the reader's buffer and invalidates the request-line slice that
/// METHOD/PATH were about to be parsed from. `GET /health` then answered
/// with a bogus 404/400 on every attempt.
fn httpGetSplit(allocator: std.mem.Allocator, port: u16, path: []const u8) ![]u8 {
    const request_line = try std.fmt.allocPrint(allocator, "GET {s} HTTP/1.0\r\n", .{path});
    defer allocator.free(request_line);
    return httpSendRawSplit(allocator, port, request_line, "\r\n");
}

fn httpGet(allocator: std.mem.Allocator, port: u16, path: []const u8) ![]u8 {
    const request = try std.fmt.allocPrint(
        allocator,
        "GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n",
        .{ path, port },
    );
    defer allocator.free(request);
    return httpSendRaw(allocator, port, request);
}

/// Connect to 127.0.0.1:port, write `request` verbatim, and read the response
/// until it is complete or the peer closes.
fn httpSendRaw(allocator: std.mem.Allocator, port: u16, request: []const u8) ![]u8 {
    return httpSendRawSplit(allocator, port, request, "");
}

/// Same as `httpSendRaw`, but writes `head` and `tail` as two separate
/// segments with a short gap so the server observes a partial request first.
fn httpSendRawSplit(allocator: std.mem.Allocator, port: u16, head: []const u8, tail: []const u8) ![]u8 {
    const fd = try tcpSocket(false);
    defer _ = std.c.close(fd);

    const sa = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = .{0} ** 8,
    };
    const conn_raw = std.c.connect(fd, @ptrCast(&sa), @sizeOf(std.posix.sockaddr.in));
    const conn_signed = conn_raw;
    if (conn_signed < 0) return error.ConnectFailed;

    try writeAll(fd, head);
    if (tail.len > 0) {
        sleepMs(10);
        try writeAll(fd, tail);
    }

    var response: std.ArrayList(u8) = .empty;
    errdefer response.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (response.items.len < 1024 * 1024) {
        const n_rc = std.c.read(fd, &chunk, chunk.len);
        const n_signed = n_rc;
        if (n_signed < 0) return error.ReadFailed;
        if (n_signed == 0) break;
        try response.appendSlice(allocator, chunk[0..@intCast(n_signed)]);
        if (httpResponseComplete(response.items)) break;
    }

    return try response.toOwnedSlice(allocator);
}

fn runtimeSnapshotForTest(allocator: std.mem.Allocator, ctx: *anyopaque) anyerror![]u8 {
    _ = ctx;
    return try allocator.dupe(
        u8,
        "# TYPE quic_stream_write_elapsed_ns_total gauge\n" ++
            "quic_stream_write_elapsed_ns_total 42\n" ++
            "# TYPE mg_merge_tuple_lock_wait_ns_total gauge\n" ++
            "mg_merge_tuple_lock_wait_ns_total 99\n",
    );
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

test "MetricsServer /metrics appends runtime high-concurrency counters" {
    const allocator = std.heap.page_allocator;

    var collector = try prometheus.MetricsCollector.init(allocator);
    defer collector.deinit();

    const port = pickTestPort() + 3;

    var server = metrics_server.MetricsServer.init(allocator, &collector, port);
    defer server.deinit();
    metrics_server.setRuntimeSnapshotCallback(runtimeSnapshotForTest, @ptrCast(&server));
    defer metrics_server.setRuntimeSnapshotCallback(null, null);

    try server.start();
    try tryConnect(port, 1000);

    const response = try httpGet(allocator, port, "/metrics");
    defer allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "quic_stream_write_elapsed_ns_total 42") != null);
    try testing.expect(std.mem.indexOf(u8, response, "mg_merge_tuple_lock_wait_ns_total 99") != null);
}

// Bug 731 (#1): the Docker HEALTHCHECK now probes the unauthenticated
// out-of-band liveness endpoint instead of the authenticated QUIC query path.
// That only works if `/health` answers every legal HTTP client, not just the
// ones whose request happens to arrive with headers already buffered.
//
// Pre-fix: `handleConnection` parsed METHOD/PATH out of the slice returned by
// `takeDelimiterInclusive` AFTER the header-drain loop had refilled the very
// buffer that slice pointed into. A headerless request (what `bash`'s
// `/dev/tcp` sends, verified against a live server) whose trailing empty line
// lands in a second TCP segment reproduced a bogus `404 Not Found` /
// `400 Bad Request` for `GET /health` every time, while a single-segment
// request from curl or python masked it.
//
// CANARY: REQ=REQ-PROMETHEUS-WIRE-004; FEATURE="Prometheus Metrics Endpoint"; ASPECT=RequestLineLifetime; STATUS=TESTED; TEST=tests/test_metrics_server_lifecycle.zig; OWNER=monitoring; UPDATED=2026-07-31
test "MetricsServer /health answers a segment-split request (bug 731 #1)" {
    const allocator = std.heap.page_allocator;

    var collector = try prometheus.MetricsCollector.init(allocator);
    defer collector.deinit();

    const port = pickTestPort() + 4;

    var server = metrics_server.MetricsServer.init(allocator, &collector, port);
    defer server.deinit();

    try server.start();
    try tryConnect(port, 1000);

    // Repeat: the pre-fix corruption depended on buffer state, so a single
    // sample could pass by luck.
    var attempt: usize = 0;
    while (attempt < 5) : (attempt += 1) {
        const response = try httpGetSplit(allocator, port, "/health");
        defer allocator.free(response);

        try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK"));
        try testing.expect(std.mem.indexOf(u8, response, "{\"status\":\"ok\"}") != null);
    }

    // The same request shape must still route /metrics correctly.
    const metrics_response = try httpGetSplit(allocator, port, "/metrics");
    defer allocator.free(metrics_response);
    try testing.expect(std.mem.startsWith(u8, metrics_response, "HTTP/1.1 200 OK"));

    // ...and an unknown path must still 404 (the fix must not make every
    // request look like /health).
    const missing = try httpGetSplit(allocator, port, "/nope");
    defer allocator.free(missing);
    try testing.expect(std.mem.startsWith(u8, missing, "HTTP/1.1 404 Not Found"));

    server.stop();
}
