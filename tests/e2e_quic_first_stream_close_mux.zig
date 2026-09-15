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
// SONNY-1219b (review of the SONNY-1219 fix) adds two more contracts:
//
//   5. A connection does not PIN an accept worker. The first fix handed
//      connection ownership to a per-connection acceptor task that then sat on
//      an `acceptor_pool` worker until the connection died — so with W workers,
//      connection W+1 onwards silently lost multiplexing and its teardown was
//      owed to a task that never ran. More connections than workers must all
//      multiplex. Regression run: `GEODE_QUIC_ACCEPTOR_WORKERS=2`.
//   6. Served stream wrappers are released per stream, not accumulated in
//      `conn.streams` for the connection's (now much longer) life.
//
// Scenarios 3, 5 and 6 assert on the server's runtime gauges
// (`quic_active_connections`, `quic_max_tracked_streams`) scraped from the
// out-of-band `/metrics` listener, because "the server still answers" is also
// true of a server that has leaked everything it ever served.
//
// RED at 26f066c4: scenarios 1, 2 and 4 fail — every sibling stream reports
// `error.EndOfStream` / `error.Closed` off a NO_ERROR CONNECTION_CLOSE.
// RED at f80a812d under `GEODE_QUIC_ACCEPTOR_WORKERS=2`: scenario 5 fails from
// the 3rd connection on, and scenario 6 fails for want of the gauge.
//
// Executable, not a `test`: `builtin.is_test` turns on verbose byte dumps
// inside the vendored QUIC dependency, exactly as documented for
// tests/e2e_quic_high_concurrency.zig.
//
// CANARY: REQ=REQ-QUIC-MUX-010; FEATURE="StreamMultiplexing"; ASPECT=ConnectionOutlivesFirstStream; STATUS=TESTED; TEST=test-quic-first-stream-close-mux-e2e; OWNER=server; UPDATED=2026-09-15
// CANARY: REQ=REQ-QUIC-MUX-011; FEATURE="StreamMultiplexing"; ASPECT=AcceptReactorOccupancy; STATUS=TESTED; TEST=test-quic-first-stream-close-mux-e2e; OWNER=server; UPDATED=2026-09-15

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

    /// Close the way a real client does: CONNECTION_CLOSE on the wire, THEN
    /// tear the endpoint down. `QuicClient.deinit` alone frees the endpoint
    /// silently, and a silent peer is indistinguishable from an idle one — the
    /// server would hold the connection to its 300 s idle timeout and the
    /// connection-count assertions below would be measuring that timeout
    /// instead of the server's reaping.
    fn deinit(self: *MuxConn) void {
        self.client.closeGraceful(quic.app_error.no_error);
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
fn scenario3(gpa: std.mem.Allocator, addr: []const u8, rounds: u32, metrics_port: u16) !void {
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

    // SONNY-1219b F7: "the server still answers" is also true of a server that
    // has leaked every connection it ever served, so assert on the gauge. Every
    // churned connection must be GONE — `quic_active_connections` back to zero —
    // before the liveness probe, which would otherwise mask the leak.
    const settled = waitForGauge(gpa, metrics_port, "quic_active_connections", isZero, 30_000) catch |err| {
        const last = scrapeGauge(gpa, metrics_port, "quic_active_connections") catch 0;
        std.debug.print("FAIL [scenario3]: quic_active_connections={d} after {d} cycles ({s}) — connections leaked\n", .{ last, rounds, @errorName(err) });
        return error.ConnectionLeak;
    };
    std.debug.print("[scenario3] quic_active_connections={d} after {d} cycles\n", .{ settled, rounds });

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

// ── SONNY-1219b: runtime-metric scrape helpers ──────────────────────────────
//
// F7 of the SONNY-1219 review: scenario 3 could not actually DETECT a leak —
// "the server still answers" is true of a server that has leaked every
// connection it ever served. The server's `/metrics` surface already carries
// `quic_active_connections` (registered in src/server/main.zig against
// src/server/quic_connection_metrics.zig:activeConnections), so the churn
// scenario now asserts the count returns to zero, and the new occupancy /
// wrapper scenarios assert on gauges rather than on liveness.

fn linuxWriteAll(fd: i32, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = std.os.linux.write(fd, bytes[offset..].ptr, bytes.len - offset);
        const signed: isize = @bitCast(rc);
        if (signed <= 0) return error.WriteFailed;
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

fn httpGetLoopback(allocator: std.mem.Allocator, port: u16, path: []const u8, max_bytes: usize) ![]u8 {
    const linux = std.os.linux;
    const fd_raw = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    if (linux.errno(fd_raw) != .SUCCESS) return error.SocketCreateFailed;
    const fd: i32 = @intCast(fd_raw);
    defer _ = linux.close(fd);

    const sa = linux.sockaddr.in{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F00_0001),
        .zero = .{0} ** 8,
    };
    const conn_rc = linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
    if (@as(isize, @bitCast(conn_rc)) < 0) return error.ConnectFailed;

    const request = try std.fmt.allocPrint(
        allocator,
        "GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n",
        .{ path, port },
    );
    defer allocator.free(request);
    try linuxWriteAll(fd, request);

    var response: std.ArrayList(u8) = .empty;
    errdefer response.deinit(allocator);
    var chunk: [8192]u8 = undefined;
    while (response.items.len < max_bytes) {
        const n_rc = linux.read(fd, &chunk, chunk.len);
        const signed: isize = @bitCast(n_rc);
        if (signed < 0) return error.ReadFailed;
        if (signed == 0) break;
        try response.appendSlice(allocator, chunk[0..@intCast(signed)]);
        if (httpResponseComplete(response.items)) break;
    }

    const header_end = std.mem.indexOf(u8, response.items, "\r\n\r\n") orelse return try response.toOwnedSlice(allocator);
    const owned = try allocator.dupe(u8, response.items[header_end + 4 ..]);
    response.deinit(allocator);
    return owned;
}

/// Parse one runtime gauge out of a Prometheus text body. Returns null when the
/// metric is ABSENT — the distinction matters: a missing gauge must fail the
/// assertion loudly instead of reading as a convenient zero.
fn metricValue(body: []const u8, name: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, name)) continue;
        if (line.len <= name.len or !std.ascii.isWhitespace(line[name.len])) continue;
        var rest = std.mem.trim(u8, line[name.len..], " \t");
        const end = std.mem.indexOfAny(u8, rest, " \t\r") orelse rest.len;
        rest = rest[0..end];
        return std.fmt.parseUnsigned(u64, rest, 10) catch continue;
    }
    return null;
}

/// Scrape one gauge, requiring it to be present.
fn scrapeGauge(gpa: std.mem.Allocator, metrics_port: u16, name: []const u8) !u64 {
    const body = try httpGetLoopback(gpa, metrics_port, "/metrics", 4 * 1024 * 1024);
    defer gpa.free(body);
    return metricValue(body, name) orelse error.MetricAbsent;
}

/// Poll a gauge until it satisfies `want`, or the deadline elapses.
fn waitForGauge(
    gpa: std.mem.Allocator,
    metrics_port: u16,
    name: []const u8,
    want: *const fn (u64) bool,
    deadline_ms: u64,
) !u64 {
    var waited: u64 = 0;
    var last: u64 = 0;
    while (waited <= deadline_ms) : (waited += 100) {
        last = scrapeGauge(gpa, metrics_port, name) catch |err| {
            if (err == error.MetricAbsent) return err;
            sleepMs(100);
            continue;
        };
        if (want(last)) return last;
        sleepMs(100);
    }
    return error.GaugeNeverSettled;
}

fn isZero(v: u64) bool {
    return v == 0;
}

// ── Scenario 5: a connection must not pin an acceptor worker ────────────────
//
// SONNY-1219b F1. The SONNY-1219 fix handed connection ownership to the
// per-connection acceptor task, and that task then sat on an `acceptor_pool`
// worker for the WHOLE connection lifetime — the loop only exits on
// `conn.isDrained()` / `conn.shutdown_requested`, i.e. at the 300 s QUIC idle
// timeout for a connection whose peer is still there. With `W` acceptor
// workers, connection `W+1` onwards silently loses multiplexing: its acceptor
// task is queued (submit() returns true while the 4096-deep queue has room) but
// never scheduled, so nothing ever calls `tryAcceptStream` for it and every
// sibling stream hangs to the client's timeout. The teardown handed to that
// task is owed to something that is not running.
//
// This scenario holds `conn_count` connections open SIMULTANEOUSLY, closes the
// first stream on each (the SONNY-1219 handoff), and then uses every one of
// them. Run under `GEODE_QUIC_ACCEPTOR_WORKERS=2` it is the F1 regression:
// pre-fix the 3rd connection onwards fails.
/// `std.posix.environ` was retired in Zig 0.16 and linking libc just to read one
/// variable is not worth it, so read /proc/self/environ — the same stdlib-only,
/// linux-only idiom `tests/proto_test_util.zig:spawnServer` already uses.
fn envValue(name: []const u8, buf: []u8) ?[]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var f = std.Io.Dir.cwd().openFile(io, "/proc/self/environ", .{ .mode = .read_only }) catch return null;
    defer f.close(io);
    const n = f.readPositionalAll(io, buf, 0) catch return null;
    const data = buf[0..n];
    var start: usize = 0;
    for (data, 0..) |c, i| {
        if (c != 0) continue;
        if (i > start) {
            const entry = data[start..i];
            if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
                if (std.mem.eql(u8, entry[0..eq], name)) return entry[eq + 1 ..];
            }
        }
        start = i + 1;
    }
    return null;
}

fn acceptorWorkerEnv() ?u32 {
    var buf: [64 * 1024]u8 = undefined;
    const raw = envValue("GEODE_QUIC_ACCEPTOR_WORKERS", &buf) orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return std.fmt.parseUnsigned(u32, trimmed, 10) catch null;
}

/// More connections than acceptor workers, always. With the env var set (the
/// regression run) that is workers+3; without it, a fixed 12 — enough to prove
/// the reactor serves many connections per thread without making the default
/// run pay for 67 connections.
fn occupancyConnCount() u32 {
    if (acceptorWorkerEnv()) |w| return @min(w, 64) + 3;
    return 12;
}

fn scenario5(gpa: std.mem.Allocator, addr: []const u8, metrics_port: u16) !void {
    const conn_count = occupancyConnCount();
    std.debug.print("[scenario5] connections outlive acceptor workers (conns={d}, GEODE_QUIC_ACCEPTOR_WORKERS={?d})\n", .{ conn_count, acceptorWorkerEnv() });

    const conns = try gpa.alloc(MuxConn, conn_count);
    defer gpa.free(conns);
    const live = try gpa.alloc(bool, conn_count);
    defer gpa.free(live);
    @memset(live, false);
    defer for (conns, live) |*c, was_live| {
        if (was_live) c.deinit();
    };

    // Phase A: open every connection, HELLO on its first stream, then close
    // that first stream — the exact hand-off the acceptor is supposed to take.
    for (conns, live, 0..) |*c, *was_live, i| {
        c.* = MuxConn.connect(gpa, addr) catch |err| {
            std.debug.print("[scenario5] conn {d}: connect failed: {s}\n", .{ i, @errorName(err) });
            return error.OccupancyConnectFailed;
        };
        was_live.* = true;
        var first = try c.openStream();
        try helloAndQuery(gpa, &first);
        c.releaseStream(&first);
    }
    std.debug.print("[scenario5] {d} connections open, first stream closed on each\n", .{conn_count});

    // The gauge must see every one of them. A connection that the engine has
    // already torn down would not be counted, so this also pins that the
    // hand-off did not destroy anything.
    const active = try scrapeGauge(gpa, metrics_port, "quic_active_connections");
    if (active < conn_count) {
        std.debug.print("FAIL [scenario5]: quic_active_connections={d}, expected >= {d}\n", .{ active, conn_count });
        return error.ConnectionsDisappeared;
    }

    // Phase B: every connection must still multiplex. Pre-fix, connections
    // beyond the acceptor-worker count have no running acceptor at all.
    sleepMs(250);
    var failures: u32 = 0;
    for (conns, 0..) |*c, i| {
        var s = c.openStream() catch |err| {
            std.debug.print("[scenario5] conn {d}: open failed: {s}\n", .{ i, @errorName(err) });
            failures += 1;
            continue;
        };
        defer c.releaseStream(&s);
        helloAndQuery(gpa, &s) catch |err| {
            std.debug.print("[scenario5] conn {d}: {s}\n", .{ i, @errorName(err) });
            failures += 1;
            continue;
        };
    }
    if (failures != 0) {
        std.debug.print("FAIL [scenario5]: {d}/{d} connections lost multiplexing (acceptor workers exhausted)\n", .{ failures, conn_count });
        return error.AcceptorWorkerExhaustion;
    }
    std.debug.print("[scenario5] OK: {d}/{d} connections multiplexed with {?d} acceptor workers\n", .{ conn_count, conn_count, acceptorWorkerEnv() });
}

// ── Scenario 6: served stream wrappers are released, not accumulated ────────
//
// SONNY-1219b F2. `handleAdditionalStream`'s defer called `stream.close()` but
// never `conn.destroyStream(stream)`, so every served sibling left a
// `*QuicStream` wrapper in `conn.streams` until the whole connection was
// destroyed. Before SONNY-1219 that was bounded by the first stream's life;
// afterwards a pooled connection lives for hours and the list is unbounded.
//
// Assert on `quic_max_tracked_streams` — the largest `conn.streams` length over
// the live connections. Serving `wrapper_churn_streams` streams one at a time
// must leave it small; pre-fix it grows to the churn count.
const wrapper_churn_streams: u32 = 48;
const wrapper_tracked_bound: u64 = 8;

fn scenario6(gpa: std.mem.Allocator, addr: []const u8, metrics_port: u16) !void {
    std.debug.print("[scenario6] stream wrappers released per stream (churn={d})\n", .{wrapper_churn_streams});
    var conn = try MuxConn.connect(gpa, addr);
    defer conn.deinit();

    var first = try conn.openStream();
    try helloAndQuery(gpa, &first);
    defer conn.releaseStream(&first);

    var i: u32 = 0;
    while (i < wrapper_churn_streams) : (i += 1) {
        var s = try conn.openStream();
        try helloAndQuery(gpa, &s);
        conn.releaseStream(&s);
    }
    // Give the server a moment to run each handler's release defer.
    sleepMs(500);

    const tracked = scrapeGauge(gpa, metrics_port, "quic_max_tracked_streams") catch |err| {
        std.debug.print("FAIL [scenario6]: quic_max_tracked_streams unavailable: {s}\n", .{@errorName(err)});
        return error.TrackedStreamGaugeMissing;
    };
    if (tracked > wrapper_tracked_bound) {
        std.debug.print(
            "FAIL [scenario6]: quic_max_tracked_streams={d} after {d} served streams (bound {d}) — wrappers are accumulating in conn.streams\n",
            .{ tracked, wrapper_churn_streams, wrapper_tracked_bound },
        );
        return error.StreamWrappersLeaked;
    }
    std.debug.print("[scenario6] OK: quic_max_tracked_streams={d} after {d} served streams\n", .{ tracked, wrapper_churn_streams });
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
    // SONNY-1219b F7: the assertions below read the server's runtime gauges, so
    // the out-of-band metrics listener has to be up. `GEODE_QUIC_ACCEPTOR_WORKERS`
    // is deliberately NOT set here — it is inherited from this process's
    // environment so the regression run is `GEODE_QUIC_ACCEPTOR_WORKERS=2 zig
    // build test-quic-first-stream-close-mux-e2e`.
    const metrics_port = try util.getRandomPort();
    const metrics_port_env = try std.fmt.allocPrint(gpa, "GEODE_METRICS_PORT={d}", .{metrics_port});
    defer gpa.free(metrics_port_env);
    var server = try util.spawnServerRandom(gpa, &.{
        "GEODE_QUIC_ENABLE_STREAM_MULTIPLEXING=1",
        "GEODE_METRICS_BIND=127.0.0.1",
        metrics_port_env,
    });
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
    scenario3(gpa, addr, 8, metrics_port) catch |err| {
        std.debug.print("[scenario3] FAILED: {s}\n", .{@errorName(err)});
        failed += 1;
    };
    for (race_stream_counts) |n| {
        inFlightScenario(gpa, addr, "scenario4", n, 0) catch |err| {
            std.debug.print("[scenario4] streams={d} FAILED: {s}\n", .{ n, @errorName(err) });
            failed += 1;
        };
    }

    scenario5(gpa, addr, metrics_port) catch |err| {
        std.debug.print("[scenario5] FAILED: {s}\n", .{@errorName(err)});
        failed += 1;
    };
    scenario6(gpa, addr, metrics_port) catch |err| {
        std.debug.print("[scenario6] FAILED: {s}\n", .{@errorName(err)});
        failed += 1;
    };

    if (failed != 0) {
        std.debug.print("FAIL: SONNY-1219 — {d} scenario(s) failed\n", .{failed});
        return error.FirstStreamCloseKillsConnection;
    }
    std.debug.print("PASS: SONNY-1219 — QUIC connections outlive their first stream\n", .{});
}
