// SONNY-1219 / GEO-UP-007: a QUIC connection must outlive its FIRST stream.
//
// Defect (engine main 26f066c4 and tag v0.8.15): the server tied a QUIC
// connection's lifetime to the first stream opened on it. When the
// HELLO-bearing stream closed, `cleanupFirstStreamOwner`
// (src/server/quic_connection_handler.zig) shut the per-connection stream
// acceptor down and `destroyFirstStreamOwnerResources` destroyed the whole
// connection via `transport.destroyConnection` ->
// `api.closeConnection(conn.inner, 0)`. Every sibling multiplexed stream died
// — including ones with a request already in flight — and the client saw a
// CONNECTION_CLOSE carrying application error code 0 (NO_ERROR) with no reason
// string and no server log line. `waitForAllStreamsDrained` did not protect the
// siblings, because a stream is only counted once the acceptor has REGISTERED
// it and the acceptor had just been told to stop.
//
// Reported symptom (Go driver `TestLoad_BurstExceedsPoolSize_NoDeadlock`): a
// burst of 64 requests over a pool of 8 multiplexed QUIC connections completed
// 8 and failed 56 with
//   failed to receive HELLO response: geode: transport read_length to ...: NO_ERROR (remote)
// Successes always equalled the number of QUIC CONNECTIONS, never the number of
// streams — exactly one stream per connection survived.
//
// Contract under test (the fix):
//   1. Closing the first stream does not close the connection. Streams opened
//      AFTER the first stream closed still authenticate and run queries.
//   2. Closing the first stream while siblings have requests in flight does not
//      drop those requests.
//   3. The connection is still reaped when its last stream goes away — the
//      refcount fix must not trade a teardown bug for a leak.
//   4. The acceptance race is closed: a stream the client opened but the
//      acceptor has not yet returned from `tryAcceptStream` is not destroyed
//      pre-acceptance, for N in {2, 8, 32} opened across the first stream's
//      close.
//
// RED at 26f066c4: scenarios 1, 2 and 4 fail — every sibling stream reports
// `error.EndOfStream` / `error.Closed` off a NO_ERROR CONNECTION_CLOSE.
//
// Executable, not a `test`: `builtin.is_test` turns on verbose byte dumps
// inside the vendored QUIC dependency, exactly as documented for
// tests/e2e_quic_high_concurrency.zig.
//
// CANARY: REQ=REQ-QUIC-MUX-010; FEATURE="StreamMultiplexing"; ASPECT=ConnectionOutlivesFirstStream; STATUS=TESTED; TEST=test-quic-first-stream-close-mux-e2e; OWNER=server; UPDATED=2026-09-15

const std = @import("std");
const builtin = @import("builtin");
const util = @import("proto_test_util.zig");
const schema = @import("schema");
const quic = @import("transport/quic");

// Generous on purpose: this harness is routinely run on a box that is also
// building, so a tight budget turns a scheduling delay into a false RED. The
// defect under test fails instantly (the connection is gone), never slowly.
/// PID of the spawned `geode serve` child, published so the PANIC path can
/// still reap it. `ServerHandle.deinit` runs from a `defer` and covers every
/// normal and error exit, but a panic aborts the process without unwinding —
/// and an orphaned `geode serve` then spins at 60-70% CPU until someone
/// notices it. 0 means "no child" / "already reaped".
var g_server_pid: std.atomic.Value(i32) = std.atomic.Value(i32).init(0);

pub const panic = std.debug.FullPanic(panicReapServer);

fn panicReapServer(msg: []const u8, first_trace_addr: ?usize) noreturn {
    const pid = g_server_pid.swap(0, .acq_rel);
    if (pid > 0) std.posix.kill(pid, .KILL) catch {};
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// Consecutive read failures after which a scenario stops waiting on the rest.
/// Once the server has destroyed the connection every remaining stream costs a
/// full `hello_timeout_ms`, which turned a RED run into ~18 minutes. The
/// connection is provably gone by then, so the remaining streams are counted as
/// failed without paying for their timeouts.
const max_consecutive_read_failures: u32 = 3;

const hello_timeout_ms: u32 = 20_000;
const query_timeout_secs: u32 = 20;

/// Scenario 4 fan-outs. The triage asked for {2, 8, 64}; the per-connection cap
/// is 65 INCLUDING the first stream (src/server/active_stream_registry.zig), so
/// 64 siblings sits exactly on the boundary while the first stream is still
/// being closed and would make the pin timing-dependent. 32 keeps clear
/// headroom and still exercises the acceptance race at real fan-out.
const race_stream_counts = [_]u32{ 2, 8, 32 };

fn sleepMs(ms: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

const Addr = struct { host: []const u8, port: u16 };

fn parseAddr(addr: []const u8) !Addr {
    const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse return error.InvalidAddress;
    if (colon == 0) return error.InvalidAddress;
    return .{ .host = addr[0..colon], .port = try std.fmt.parseInt(u16, addr[colon + 1 ..], 10) };
}

/// A multiplexed connection: ONE `quic.QuicClient` with many streams on it.
///
/// `util.QuicProtoClient` owns its `quic.QuicClient` by value and pairs it 1:1
/// with a single stream, so it cannot express multiplexing on its own. `wrap`
/// builds a BORROWING `QuicProtoClient` over a sibling stream: the embedded
/// client is a shallow copy (allocator + endpoint/connection pointers, all
/// owned by `MuxConn`), so a wrapper must be released with `releaseStream`,
/// never with `QuicProtoClient.deinit` (which would tear the endpoint down).
const MuxConn = struct {
    allocator: std.mem.Allocator,
    client: quic.QuicClient,

    fn connect(allocator: std.mem.Allocator, addr: []const u8) !MuxConn {
        const parsed = try parseAddr(addr);
        var client = quic.QuicClient.init(allocator);
        errdefer client.deinit();
        try client.connectInsecure(parsed.host, parsed.port, true);
        try client.waitForHandshake(10);
        return .{ .allocator = allocator, .client = client };
    }

    fn deinit(self: *MuxConn) void {
        self.client.deinit();
    }

    /// Open an additional client-initiated bidirectional stream on this
    /// connection and wrap it for the protobuf helpers.
    fn openStream(self: *MuxConn) !util.QuicProtoClient {
        const stream = try self.client.openStream(true);
        return .{ .allocator = self.allocator, .client = self.client, .stream = stream };
    }

    /// Close one stream WITHOUT touching the connection. This is the operation
    /// that used to kill every sibling stream.
    fn releaseStream(self: *MuxConn, s: *util.QuicProtoClient) void {
        _ = self;
        s.stream.deinit();
        if (s.session_id.len > 0) s.allocator.free(s.session_id);
        s.session_id = "";
    }
};

/// HELLO + one trivial query on a stream, proving it is fully usable.
fn helloAndQuery(gpa: std.mem.Allocator, s: *util.QuicProtoClient) !void {
    var hello_res = try s.helloWithTimeout(gpa, util.defaultUsername(), util.defaultPassword(), hello_timeout_ms);
    defer hello_res.deinit(gpa);
    if (!hello_res.success) return error.HelloRejected;

    var result = try s.executeAndCollectWithTimeout(gpa, "RETURN 1 AS n", util.emptyParams(), 100, query_timeout_secs);
    defer result.deinit(gpa);
}

// ── Scenario 1: the connection outlives its first stream ────────────────────
//
// The purest form of the defect, and the one that made the Go pool hand out
// already-dead connections: close the first stream, wait, then use the
// connection again. Deterministic — no race window.
fn scenario1(gpa: std.mem.Allocator, addr: []const u8, sibling_count: u32) !void {
    std.debug.print("[scenario1] connection outlives first stream (siblings={d})\n", .{sibling_count});
    var conn = try MuxConn.connect(gpa, addr);
    defer conn.deinit();

    var first = try conn.openStream();
    try helloAndQuery(gpa, &first);
    conn.releaseStream(&first);
    std.debug.print("[scenario1] first stream closed\n", .{});

    // Let the server's first-stream cleanup run to completion. Pre-fix this is
    // exactly when the connection was destroyed with NO_ERROR.
    sleepMs(250);

    var failures: u32 = 0;
    var consecutive_failures: u32 = 0;
    var i: u32 = 0;
    while (i < sibling_count) : (i += 1) {
        if (consecutive_failures >= max_consecutive_read_failures) {
            // The connection is gone; count the rest without paying a timeout each.
            failures += 1;
            continue;
        }
        var s = conn.openStream() catch |err| {
            std.debug.print("[scenario1] stream {d}: open failed: {s}\n", .{ i, @errorName(err) });
            failures += 1;
            consecutive_failures += 1;
            continue;
        };
        defer conn.releaseStream(&s);
        helloAndQuery(gpa, &s) catch |err| {
            std.debug.print("[scenario1] stream {d}: {s}\n", .{ i, @errorName(err) });
            failures += 1;
            consecutive_failures += 1;
            continue;
        };
        consecutive_failures = 0;
    }
    if (failures != 0) {
        std.debug.print("FAIL [scenario1]: {d}/{d} streams died after the first stream closed\n", .{ failures, sibling_count });
        return error.ConnectionDiedWithFirstStream;
    }
    std.debug.print("[scenario1] OK: {d}/{d} streams served after the first stream closed\n", .{ sibling_count, sibling_count });
}

// ── Scenarios 2 and 4: close the first stream under in-flight siblings ──────
//
// Every sibling stream is opened and its HELLO request WRITTEN before any
// response is read, so all N requests are provably on the wire and unanswered.
// `close_after` decides where in that sequence the first stream closes:
//
//   null (scenario 2): close after every request is written. The assertion is
//     that in-flight requests survive the first stream's close.
//   0 (scenario 4): close right after the FIRST sibling's request is written,
//     so the remaining N-1 streams are opened while the server is running its
//     first-stream cleanup. A stream opened in that window can still be sitting
//     in the acceptor's queue — opened by the peer, not yet returned from
//     `tryAcceptStream`, therefore not registered and invisible to
//     `waitForAllStreamsDrained`. That is the acceptance race.
//
// Single-threaded on purpose: the ordering that matters is on the wire, and a
// client-side helper thread would only add scheduling noise (and, at 512 KiB,
// a `pthread_create` EINVAL under a loaded box) to a server-side assertion.
fn inFlightScenario(
    gpa: std.mem.Allocator,
    addr: []const u8,
    label: []const u8,
    stream_count: u32,
    close_after: ?u32,
) !void {
    std.debug.print("[{s}] streams={d} close_after={?d}\n", .{ label, stream_count, close_after });
    var conn = try MuxConn.connect(gpa, addr);
    defer conn.deinit();

    var first = try conn.openStream();
    try helloAndQuery(gpa, &first);
    var first_closed = false;

    const siblings = try gpa.alloc(util.QuicProtoClient, stream_count);
    defer gpa.free(siblings);
    const opened = try gpa.alloc(bool, stream_count);
    defer gpa.free(opened);
    @memset(opened, false);
    defer for (siblings, opened) |*s, was_opened| {
        if (was_opened) conn.releaseStream(s);
    };

    const hello_req = schema.HelloRequest{
        .username = util.defaultUsername(),
        .password = util.defaultPassword(),
        .tenant_id = null,
        .client_name = "sonny-1219",
        .client_version = "0.0.0",
        .wanted_conformance = "min",
    };

    var failures: u32 = 0;
    for (siblings, opened, 0..) |*s, *was_opened, i| {
        s.* = conn.openStream() catch |err| {
            std.debug.print("[{s}] stream {d}: open failed: {s}\n", .{ label, i, @errorName(err) });
            failures += 1;
            continue;
        };
        was_opened.* = true;
        s.writeMessage(.{ .hello = hello_req }) catch |err| {
            std.debug.print("[{s}] stream {d}: write failed: {s}\n", .{ label, i, @errorName(err) });
            failures += 1;
        };
        if (close_after) |at| {
            if (i == at and !first_closed) {
                conn.releaseStream(&first);
                first_closed = true;
                std.debug.print("[{s}] first stream closed after sibling {d}\n", .{ label, i });
            }
        }
    }
    if (!first_closed) {
        // Every sibling request is on the wire and unanswered — now close.
        conn.releaseStream(&first);
        first_closed = true;
        std.debug.print("[{s}] first stream closed after all writes\n", .{label});
    }

    var consecutive_failures: u32 = 0;
    var abandoned: u32 = 0;
    for (siblings, opened, 0..) |*s, was_opened, i| {
        if (!was_opened) continue;
        if (consecutive_failures >= max_consecutive_read_failures) {
            // The connection is gone; do not pay a timeout per remaining stream.
            abandoned += 1;
            failures += 1;
            continue;
        }
        var packet = s.readPacket(gpa, hello_timeout_ms) catch |err| {
            if (failures < 8) std.debug.print("[{s}] stream {d}: {s}\n", .{ label, i, @errorName(err) });
            failures += 1;
            consecutive_failures += 1;
            continue;
        };
        defer packet.deinit(gpa);
        consecutive_failures = 0;
        const msg = packet.quic orelse {
            failures += 1;
            continue;
        };
        if (msg != .hello or !msg.hello.success) failures += 1;
    }
    if (abandoned != 0) {
        std.debug.print("[{s}] {d} stream(s) not polled after {d} consecutive failures\n", .{ label, abandoned, max_consecutive_read_failures });
    }

    if (failures != 0) {
        std.debug.print("FAIL [{s}]: {d}/{d} multiplexed streams died when the first stream closed\n", .{ label, failures, stream_count });
        return error.SiblingStreamsKilled;
    }
    std.debug.print("[{s}] OK: {d}/{d} multiplexed streams completed\n", .{ label, stream_count, stream_count });
}

// ── Scenario 3: the connection is still reaped once its last stream ends ────
//
// The refcount fix must not trade a teardown bug for a leak. Churn a batch of
// connections that each open, use and close every stream, then assert the
// server still admits and serves fresh connections afterwards (a leaked
// connection or a wedged acceptor shows up here as an admission stall).
fn scenario3(gpa: std.mem.Allocator, addr: []const u8, rounds: u32) !void {
    std.debug.print("[scenario3] connection reaped after last stream (rounds={d})\n", .{rounds});
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        var conn = try MuxConn.connect(gpa, addr);
        var first = try conn.openStream();
        try helloAndQuery(gpa, &first);

        var sib = try conn.openStream();
        try helloAndQuery(gpa, &sib);

        conn.releaseStream(&first);
        conn.releaseStream(&sib);
        conn.deinit();
    }

    // A fresh connection must still be admitted and served.
    var probe = try MuxConn.connect(gpa, addr);
    defer probe.deinit();
    var s = try probe.openStream();
    defer probe.releaseStream(&s);
    helloAndQuery(gpa, &s) catch |err| {
        std.debug.print("FAIL [scenario3]: server stopped serving after {d} connection cycles: {s}\n", .{ rounds, @errorName(err) });
        return error.ConnectionLeak;
    };
    std.debug.print("[scenario3] OK: server healthy after {d} connection cycles\n", .{rounds});
}

pub fn main() !void {
    if (comptime builtin.os.tag != .linux) {
        std.debug.print("SKIP: linux-only subprocess harness\n", .{});
        return;
    }
    const gpa = std.heap.smp_allocator;

    const io_fs = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io_fs, "./zig-out/bin/geode", .{}) catch {
        std.debug.print("SKIP: geode binary missing; run `zig build` first\n", .{});
        return;
    };

    // Multiplexing defaults on at main, but the whole point of this regression
    // is the multiplexed path — pin it explicitly so a default flip cannot turn
    // the test green by disabling the feature under test.
    var server = try util.spawnServerRandom(gpa, &.{"GEODE_QUIC_ENABLE_STREAM_MULTIPLEXING=1"});
    defer {
        g_server_pid.store(0, .release);
        server.deinit();
    }
    if (server.child.id) |pid| g_server_pid.store(@intCast(pid), .release);
    const addr = server.getAddr();

    // Run every scenario even after one fails: a regression here is most
    // informative when you can see WHICH of the four contracts broke, and a
    // fail-fast run only ever shows the first.
    var failed: u32 = 0;
    scenario1(gpa, addr, 8) catch |err| {
        std.debug.print("[scenario1] FAILED: {s}\n", .{@errorName(err)});
        failed += 1;
    };
    inFlightScenario(gpa, addr, "scenario2", 8, null) catch |err| {
        std.debug.print("[scenario2] FAILED: {s}\n", .{@errorName(err)});
        failed += 1;
    };
    scenario3(gpa, addr, 8) catch |err| {
        std.debug.print("[scenario3] FAILED: {s}\n", .{@errorName(err)});
        failed += 1;
    };
    for (race_stream_counts) |n| {
        inFlightScenario(gpa, addr, "scenario4", n, 0) catch |err| {
            std.debug.print("[scenario4] streams={d} FAILED: {s}\n", .{ n, @errorName(err) });
            failed += 1;
        };
    }

    if (failed != 0) {
        std.debug.print("FAIL: SONNY-1219 — {d} scenario(s) failed\n", .{failed});
        return error.FirstStreamCloseKillsConnection;
    }
    std.debug.print("PASS: SONNY-1219 — QUIC connections outlive their first stream\n", .{});
}
