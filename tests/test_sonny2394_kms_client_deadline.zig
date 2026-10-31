// SONNY-2394 regression: the remote-KMS client bounds its wait for a response
// by WALL-CLOCK time and fails fast on a closed connection; the remote-KMS
// server treats transport accept notifications as readiness signals, not as
// new requests.
//
// Root cause of the `test-remote-kms-hardening` ConcurrencyStress flake (15 of
// 16 clients failing with error.Timeout in roughly 1 of 10 loaded pre-push
// runs): `RemoteKmsClient.sendRequest` bounded its wait by a retry COUNT --
// 100 x (poll(50) + 10 ms sleep) -- whose wall-clock length tracks packet and
// timer activity: nominally ~6 s, measured at 1.5-2.4 s on a loaded host. A
// RemoteKmsServer processes a burst of concurrent TLS handshakes serially
// inside its endpoint poll (~22 ms each on an idle host, ~120 ms each on a
// starved CPU), so with 16 simultaneous clients it read its first request
// ~3.3 s in -- after 15 of the clients had already given up -- and then
// answered all 16 within 26 ms. Reproduced deterministically by pinning the
// test binary to one CPU shared with a busy loop (see the SONNY-2394 report).
//
// CANARY: REQ=REQ-KMS-REMOTE-CLIENT-001; FEATURE="RemoteKMSClient"; ASPECT=ResponseDeadline; STATUS=TESTED; TEST=TestSONNY2394_KmsClientWaitsOutBusyServer; OWNER=security; UPDATED=2026-09-23
// CANARY: REQ=REQ-KMS-REMOTE-CLIENT-001; FEATURE="RemoteKMSClient"; ASPECT=ResponseDeadlineWallClock; STATUS=TESTED; TEST=TestSONNY2394_KmsClientDeadlineIsWallClock; OWNER=security; UPDATED=2026-09-23
// CANARY: REQ=REQ-KMS-REMOTE-CLIENT-001; FEATURE="RemoteKMSClient"; ASPECT=ClosedConnectionFailFast; STATUS=TESTED; TEST=TestSONNY2394_KmsClientFailsFastOnClosedConnection; OWNER=security; UPDATED=2026-09-23
// CANARY: REQ=REQ-REMOTE-KMS-SERVER-001; FEATURE="Remote KMS Server"; ASPECT=SplitRequestAnsweredOnce; STATUS=TESTED; TEST=TestSONNY2394_KmsServerAnswersSplitRequestOnce; OWNER=security; UPDATED=2026-09-24
// CANARY: REQ=REQ-REMOTE-KMS-SERVER-001; FEATURE="Remote KMS Server"; ASPECT=PerConnectionRequestAssembly; STATUS=TESTED; TEST=TestSONNY2394_KmsServerAssemblesPartialRequestPerConnection; OWNER=security; UPDATED=2026-09-24
// CANARY: REQ=REQ-REMOTE-KMS-SERVER-001; FEATURE="Remote KMS Server"; ASPECT=ServingLoopNoSpin; STATUS=TESTED; TEST=TestSONNY2394_KmsServeUntilStoppedDoesNotSpin; OWNER=security; UPDATED=2026-09-24
// CANARY: REQ=REQ-KMS-REMOTE-CLIENT-001; FEATURE="RemoteKMSClient"; ASPECT=DeadlineConfigRoute; STATUS=TESTED; TEST=TestSONNY2394_KmsClientOptionsCarryDeadline; OWNER=security; UPDATED=2026-09-24
// CANARY: REQ=REQ-KMS-REMOTE-CLIENT-001; FEATURE="RemoteKMSClient"; ASPECT=HandshakeBusyServer; STATUS=TESTED; TEST=TestSONNY2394_KmsClientHandshakeWaitsOutBusyServer; OWNER=security; UPDATED=2026-10-29
// CANARY: REQ=REQ-KMS-REMOTE-CLIENT-001; FEATURE="RemoteKMSClient"; ASPECT=HandshakeDeadlineBounded; STATUS=TESTED; TEST=TestSONNY2394_KmsClientHandshakeDeadlineIsBounded; OWNER=security; UPDATED=2026-10-29

const std = @import("std");
const kms = @import("security/kms_remote"); // module provided by build.zig
const quic = @import("transport/quic");
const kms_tls = @import("kms_test_tls.zig");

fn monoMs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

/// A RemoteKmsServer driven by a background serving thread that the test can
/// PAUSE -- stop polling entirely, as a server busy with other work does -- and
/// resume. `pause()` returns only once no serving cycle is in flight, so the
/// test may then inspect the server's state.
const PausableServer = struct {
    server: kms.RemoteKmsServer,
    tls: kms_tls.TestTls,
    stop: std.atomic.Value(bool) = .init(false),
    paused: std.atomic.Value(bool) = .init(false),
    pause_seq: std.atomic.Value(u32) = .init(0),
    parked_seq: std.atomic.Value(u32) = .init(0),
    thread: ?std.Thread = null,

    fn start(self: *PausableServer, port: u16, auth: []const u8) !void {
        self.* = .{
            .server = try kms.RemoteKmsServer.init(std.testing.allocator, 0x2394),
            .tls = undefined,
        };
        errdefer self.server.deinit();
        self.tls = try kms_tls.TestTls.init(std.testing.allocator);
        errdefer self.tls.deinit(std.testing.allocator);
        try self.server.startWithOptions(port, self.tls.startOptions());
        try self.server.server.setAuthToken(auth);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *PausableServer) void {
        while (!self.stop.load(.acquire)) {
            if (self.paused.load(.acquire)) {
                self.parked_seq.store(self.pause_seq.load(.acquire), .release);
                sleepMs(2);
                continue;
            }
            _ = self.server.serveOnce() catch {};
        }
    }

    fn pause(self: *PausableServer) void {
        const seq = self.pause_seq.fetchAdd(1, .acq_rel) + 1;
        self.paused.store(true, .release);
        while (self.parked_seq.load(.acquire) != seq) sleepMs(1);
    }

    fn unpause(self: *PausableServer) void {
        self.paused.store(false, .release);
    }

    fn deinit(self: *PausableServer) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
        self.server.deinit();
        self.tls.deinit(std.testing.allocator);
    }
};

fn unpauseAfter(ps: *PausableServer, ms: u64) void {
    sleepMs(ms);
    ps.unpause();
}

// Clients stay on page_allocator (see the GAP-0514 P3 note in
// tests/canary_remote_kms.zig: the pinned vendor TLS stack leaks client
// handshake allocations); the server side runs under std.testing.allocator.
fn connectClient(port: u16, auth: []const u8) !kms.RemoteKmsClient {
    var client = kms.RemoteKmsClient.init(std.heap.page_allocator);
    errdefer client.deinit();
    try client.connect("127.0.0.1", port);
    client.setAuthToken(auth);
    return client;
}

// The serving loop also handles TLS handshakes. A burst of concurrent
// clients can keep it busy beyond the old, hard-coded ten-second connect
// timeout, before the response deadline can help any of those clients.
test "TestSONNY2394_KmsClientHandshakeWaitsOutBusyServer" {
    const port: u16 = 13181;
    var ps: PausableServer = undefined;
    try ps.start(port, "handshake-token");
    defer ps.deinit();

    ps.pause();
    const busy_ms: u64 = 11_000;
    const t0 = monoMs();
    const resumer = try std.Thread.spawn(.{}, unpauseAfter, .{ &ps, busy_ms });
    defer resumer.join();
    var client = try connectClient(port, "handshake-token");
    defer client.deinit();
    try std.testing.expect(monoMs() - t0 >= busy_ms);
    const env = try client.generate();
    _ = try client.unwrap(env);
}

// A server that never resumes must still fail at the configured handshake
// deadline without marking the client connected.
test "TestSONNY2394_KmsClientHandshakeDeadlineIsBounded" {
    const port: u16 = 13182;
    var ps: PausableServer = undefined;
    try ps.start(port, "handshake-token");
    defer ps.deinit();
    ps.pause();

    var client = kms.RemoteKmsClient.initWithOptions(std.heap.page_allocator, .{ .handshake_timeout_secs = 1 });
    defer client.deinit();
    const t0 = monoMs();
    try std.testing.expectError(error.HandshakeError, client.connect("127.0.0.1", port));
    const waited = monoMs() - t0;
    try std.testing.expect(waited >= 1_000);
    try std.testing.expect(waited < 5_000);
    try std.testing.expect(!client.connected);
}

// A live server that is busy (not polling at all) for longer than the old retry
// budget could ever last -- 100 x (poll(50) + 10 ms) <= ~6 s, and far less once
// timers fire -- must still get its answer delivered: the client waits on a
// wall-clock deadline, not on a count of empty polls.
test "TestSONNY2394_KmsClientWaitsOutBusyServer" {
    const port: u16 = 13061;
    var ps: PausableServer = undefined;
    try ps.start(port, "deadline-token");
    defer ps.deinit();

    var client = try connectClient(port, "deadline-token");
    defer client.deinit();
    const env = try client.generate();
    const expected = try client.unwrap(env);

    ps.pause();
    const busy_ms: u64 = 8_000;
    const t0 = monoMs();
    const resumer = try std.Thread.spawn(.{}, unpauseAfter, .{ &ps, busy_ms });
    defer resumer.join();

    const plain = client.unwrap(env) catch |err| {
        std.debug.print("[SONNY-2394] unwrap against a server busy for {d} ms failed after {d} ms: {s}\n", .{ busy_ms, monoMs() - t0, @errorName(err) });
        return err;
    };
    const waited = monoMs() - t0;
    try std.testing.expectEqualSlices(u8, &expected, &plain);
    // The answer really came from the resumed server, not from before the pause.
    try std.testing.expect(waited >= busy_ms);
}

// The deadline is the client's to set, and it is honoured as wall-clock time.
test "TestSONNY2394_KmsClientDeadlineIsWallClock" {
    const port: u16 = 13062;
    var ps: PausableServer = undefined;
    try ps.start(port, "deadline-token");
    defer ps.deinit();

    var client = try connectClient(port, "deadline-token");
    defer client.deinit();
    const env = try client.generate();

    ps.pause();
    defer ps.unpause();
    client.response_timeout_ms = 400;
    const t0 = monoMs();
    try std.testing.expectError(error.Timeout, client.unwrap(env));
    const waited = monoMs() - t0;
    try std.testing.expect(waited >= 400);
    // Generous ceiling: it is the deadline that ended the wait, not a retry budget.
    try std.testing.expect(waited < 5_000);
}

const Waiter = struct {
    client: *kms.RemoteKmsClient,
    env: kms.Envelope,
    result: anyerror![32]u8 = error.NotRun,
    finished_ms: u64 = 0,

    fn run(self: *Waiter) void {
        self.result = self.client.unwrap(self.env);
        self.finished_ms = monoMs();
    }
};

// A request that is outstanding when the server shuts down (CONNECTION_CLOSE to
// every client) fails promptly with error.ConnectionClosed instead of waiting
// out its whole response deadline.
test "TestSONNY2394_KmsClientFailsFastOnClosedConnection" {
    const port: u16 = 13063;
    var ps: PausableServer = undefined;
    try ps.start(port, "deadline-token");
    var server_alive = true;
    defer if (server_alive) ps.deinit();

    var client = try connectClient(port, "deadline-token");
    defer client.deinit();
    const env = try client.generate();

    // The server goes quiet with the next request unanswered...
    ps.pause();
    var waiter = Waiter{ .client = &client, .env = env };
    const t = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});
    sleepMs(300);
    // ...then shuts down: RemoteKmsServer.deinit sends CONNECTION_CLOSE.
    ps.deinit();
    server_alive = false;
    const closed_ms = monoMs();
    t.join();

    const after_close = waiter.finished_ms -| closed_ms;
    if (waiter.result) |_| {
        return error.UnexpectedResponse;
    } else |err| {
        if (err != error.ConnectionClosed) {
            std.debug.print("[SONNY-2394] outstanding request ended {d} ms after the server closed, with error.{s} (want ConnectionClosed)\n", .{ after_close, @errorName(err) });
            return error.TestExpectedConnectionClosed;
        }
    }
    // Well inside the default 30 s deadline.
    try std.testing.expect(after_close < 10_000);
}

/// Poll `client` and read one response line from `stream`, for at most
/// `timeout_ms` of wall-clock time.
fn readResponseLine(client: *kms.RemoteKmsClient, stream: *quic.QuicClientStream, timeout_ms: u64) ![]u8 {
    const deadline = monoMs() + timeout_ms;
    while (true) {
        try client.quic_client.?.poll(20);
        return stream.readLine(8192) catch |err| {
            if (err != error.WouldBlock) return err;
            if (monoMs() >= deadline) return error.Timeout;
            continue;
        };
    }
}

// The transport announces a request stream once per arriving datagram, so a
// request that reaches the server in pieces can be announced more than once
// (see the same note in src/server/quic_connection_handler.zig). However many
// announcements there were, the request is answered exactly once and no
// stream wrapper outlives it.
test "TestSONNY2394_KmsServerAnswersSplitRequestOnce" {
    const port: u16 = 13064;
    var ps: PausableServer = undefined;
    try ps.start(port, "stale-token");
    defer ps.deinit();

    var client = try connectClient(port, "stale-token");
    defer client.deinit();

    // Both halves of one request line arrive while the server is not polling.
    ps.pause();
    var stream = try client.quic_client.?.getStream();
    defer stream.close();
    try stream.writeAll("{\"op\":\"Generate\",");
    try stream.writeAll("\"auth\":\"stale-token\"}\n");
    ps.unpause();

    const line = try readResponseLine(&client, stream, 10_000);
    defer std.heap.page_allocator.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"status\":\"OK\"") != null);

    // Let the server finish with the stream (bounded), then inspect it parked.
    const give_up_ms = monoMs() + 10_000;
    while (true) {
        ps.pause();
        const sc = &ps.server.conns.items[0];
        if ((sc.pending.items.len == 0 and sc.conn.trackedStreamCount() == 0) or monoMs() >= give_up_ms) break;
        ps.unpause();
        sleepMs(20);
    }
    defer ps.unpause();

    try std.testing.expectEqual(@as(u64, 1), ps.server.stats.requests_served);
    try std.testing.expectEqual(@as(usize, 1), ps.server.conns.items.len);
    try std.testing.expectEqual(@as(usize, 0), ps.server.conns.items[0].pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), ps.server.conns.items[0].conn.trackedStreamCount());
}

// Per-connection handling (review): a request whose line arrives in pieces --
// the second piece well after the first -- must still be answered, and must
// not hold up requests on other connections meanwhile. The old serving loop
// read the partial line with a blocking retry, gave up after ~50 ms and closed
// the stream, so the request was lost.
test "TestSONNY2394_KmsServerAssemblesPartialRequestPerConnection" {
    const port: u16 = 13065;
    var ps: PausableServer = undefined;
    try ps.start(port, "partial-token");
    defer ps.deinit();

    var slow = try connectClient(port, "partial-token");
    defer slow.deinit();
    var fast = try connectClient(port, "partial-token");
    defer fast.deinit();

    var stream = try slow.quic_client.?.getStream();
    defer stream.close();
    try stream.writeAll("{\"op\":\"Generate\",");

    // Another connection is served while the first request is incomplete.
    const env = try fast.generate();
    _ = try fast.unwrap(env);
    sleepMs(300);

    try stream.writeAll("\"auth\":\"partial-token\"}\n");
    const line = try readResponseLine(&slow, stream, 10_000);
    defer std.heap.page_allocator.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"status\":\"OK\"") != null);
}

const StopWatch = struct {
    server: *kms.RemoteKmsServer,
    stop: *std.atomic.Value(bool),
    returned: std.atomic.Value(bool) = .init(false),

    fn run(self: *StopWatch) void {
        self.server.serveUntilStopped(self.stop);
        self.returned.store(true, .release);
    }
};

// serveUntilStopped must not spin on a server that cannot serve: a server
// that was never started returns at once instead of burning a core until
// someone sets `stop`.
test "TestSONNY2394_KmsServeUntilStoppedDoesNotSpin" {
    var server = try kms.RemoteKmsServer.init(std.testing.allocator, 0x2394);
    defer server.deinit();
    var stop = std.atomic.Value(bool).init(false);
    var watch = StopWatch{ .server = &server, .stop = &stop };
    const t = try std.Thread.spawn(.{}, StopWatch.run, .{&watch});
    const deadline = monoMs() + 2_000;
    while (!watch.returned.load(.acquire) and monoMs() < deadline) sleepMs(5);
    const returned_on_its_own = watch.returned.load(.acquire);
    stop.store(true, .release);
    t.join();
    try std.testing.expect(returned_on_its_own);
}

// The response deadline has a configuration route (KMSConfig.remote_response_timeout_ms
// reaches production KMSProvider callers through initWithOptions).
test "TestSONNY2394_KmsClientOptionsCarryDeadline" {
    const default_client = kms.RemoteKmsClient.init(std.heap.page_allocator);
    try std.testing.expectEqual(kms.RemoteKmsClient.default_response_timeout_ms, default_client.response_timeout_ms);
    try std.testing.expectEqual(kms.RemoteKmsClient.default_handshake_timeout_secs, default_client.handshake_timeout_secs);
    const configured = kms.RemoteKmsClient.initWithOptions(std.heap.page_allocator, .{ .response_timeout_ms = 1234, .handshake_timeout_secs = 2 });
    try std.testing.expectEqual(@as(u32, 1234), configured.response_timeout_ms);
    try std.testing.expectEqual(@as(u32, 2), configured.handshake_timeout_secs);
    try std.testing.expect(!configured.connected);
}

test "TestSONNY2394_KmsServeFailureBackoffIsBounded" {
    const backoff = kms.RemoteKmsServer.serveFailureBackoffMs;
    try std.testing.expectEqual(@as(i64, 10), backoff(1));
    try std.testing.expectEqual(@as(i64, 20), backoff(2));
    try std.testing.expectEqual(@as(i64, 640), backoff(7));
    try std.testing.expectEqual(@as(i64, 1000), backoff(8));
    try std.testing.expectEqual(@as(i64, 1000), backoff(1000));
}
