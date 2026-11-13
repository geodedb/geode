// SONNY-6466: a read a QUIC client abandons must stop promptly, both when the
// client closes its connection and when it vanishes without a word.
//
// Two defects, each driven against a real `geode serve` over real QUIC with a
// comma join whose WHERE keeps no binding (400^3 bindings, minutes of work):
//
// 1. A client that VANISHES (a crash: no CONNECTION_CLOSE) leaves nothing on
//    the wire, so the only bound is the per-connection stall watchdog
//    (src/server/main.zig): a connection none of whose streams has read a
//    message for the threshold has its reads cancelled. The watchdog grouped
//    streams by the peer's IP (`proto_reader_registry.connectionLevelStall`),
//    so ANY other open connection from the same address — every loopback
//    client, every client behind one NAT — counted as a live sibling and
//    hid the abandoned read until that other connection went quiet too. The
//    threshold was a hard-coded 60 s. The fix groups by the connection's
//    identity and reads the threshold from GEODE_QUIC_STALL_CANCEL_MS. The
//    test sets 10 s, keeps a second, idle-but-live connection open from the
//    same address, and asserts the server is idle within 30 s of the client
//    vanishing — and that the bystander connection still answers.
//
// 2. A client that CLOSES (CONNECTION_CLOSE) while its read runs on a SIBLING
//    stream — the connection's first stream already ended, so the accept
//    reactor owns the connection — kept running to the watchdog: the reactor
//    set the connection's cancel flag only while the first-stream owner still
//    held the connection. The test runs with the default 60 s threshold and
//    asserts idle within 20 s.
//
// RED before the fix: case 1 stays busy past 30 s (no env knob, IP grouping),
// case 2 stays busy until the 60 s watchdog.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const schema = @import("schema");
const quic = @import("transport/quic");

/// A comma join no binding of which survives its WHERE: 400^3 = 64 million
/// bindings, each evaluated, so it runs for minutes and returns nothing.
const join_query = "MATCH (a:KP), (c:KP), (d:KP) WHERE a.i + c.i + d.i < 0 RETURN a.i";

/// Case 1's watchdog threshold, and how long after the client vanished the
/// server must be idle: the threshold, plus the watchdog's 5 s tick, plus room
/// for a loaded machine — and still half the 60 s default it used to wait for.
const vanish_stall_ms = 10_000;
const vanish_idle_deadline_ms: i64 = 30_000;

/// Case 2: well below the default 60 s watchdog.
const close_idle_deadline_ms: i64 = 20_000;

fn nowMillis() i64 {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
}

fn sleepMillis(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

/// Process `pid`'s CPU time so far (user + system), in clock ticks (1/100 s).
fn procCpuTicks(pid: std.posix.pid_t) u64 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/stat", .{pid}) catch return 0;
    var buf: [1024]u8 = undefined;
    const fd = std.c.open(path, .{});
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    const got = std.c.read(fd, &buf, buf.len);
    if (got <= 0) return 0;
    const text = buf[0..@intCast(got)];
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return 0;
    var fields = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    var i: usize = 3;
    var total: u64 = 0;
    while (fields.next()) |f| : (i += 1) {
        if (i == 14 or i == 15) total += std.fmt.parseInt(u64, f, 10) catch 0;
        if (i == 15) break;
    }
    return total;
}

/// Milliseconds from `from_ms` until a one-second window in which the server
/// spent under 30 ticks (a running join spends about 100), or null if that did
/// not happen within `limit_ms`.
fn idleAfter(pid: std.posix.pid_t, from_ms: i64, limit_ms: i64) ?i64 {
    var prev = procCpuTicks(pid);
    while (nowMillis() - from_ms < limit_ms) {
        sleepMillis(1_000);
        const now_t = procCpuTicks(pid);
        if (now_t -| prev < 30) return nowMillis() - from_ms;
        prev = now_t;
    }
    return null;
}

/// Seed 400 :KP nodes and wait for the server to go idle afterwards.
fn seed(allocator: std.mem.Allocator, addr: []const u8, pid: std.posix.pid_t) !void {
    {
        var client = try util.QuicProtoClient.connect(allocator, addr);
        defer client.deinit();
        var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        hello.deinit(allocator);
        var seeded = try client.executeAndCollectWithTimeout(allocator, "FOR i IN range(1, 400) CREATE (:KP {i: i})", util.emptyParams(), 1000, 120);
        const failed = seeded.error_code != null;
        seeded.deinit(allocator);
        if (failed) return error.SeedFailed;
    }
    if (idleAfter(pid, nowMillis(), 60_000) == null) {
        std.debug.print("SONNY-6466: the server never went idle after the seed\n", .{});
        return error.ServerNeverSettled;
    }
}

/// Send the join with no statement timeout (a timeout makes the server cancel
/// it itself) and confirm it is running: the server is busy a second later.
fn startJoin(client: *util.QuicProtoClient, pid: std.posix.pid_t) !void {
    try client.writeMessage(.{ .execute = schema.ExecuteRequest{
        .session_id = client.session_id,
        .query = join_query,
        .params = .empty,
    } });
    sleepMillis(1_000);
    const busy_from = procCpuTicks(pid);
    sleepMillis(1_000);
    const busy_ticks = procCpuTicks(pid) -| busy_from;
    if (busy_ticks < 50) std.debug.print("SONNY-6466: the join spent only {d} ticks in its second second\n", .{busy_ticks});
    try testing.expect(busy_ticks >= 50);
}

fn expectAnswers(allocator: std.mem.Allocator, client: *util.QuicProtoClient) !void {
    var one = try client.executeAndCollectWithTimeout(allocator, "RETURN 1 AS one", util.emptyParams(), 1000, 30);
    defer one.deinit(allocator);
    try testing.expect(one.error_code == null);
    try testing.expectEqual(@as(usize, 1), one.rows.len);
}

// CANARY: REQ=REQ-SONNY-6466-VANISHED-CLIENT-READ-CANCEL; FEATURE="QUIC Abandoned Read Cancellation"; ASPECT=ConnectionKeyedStallWatchdog; STATUS=TESTED; TEST=tests/test_sonny6466_abandoned_read_cancel.zig; OWNER=transport; UPDATED=2026-11-13
test "SONNY-6466 a client that vanishes without CONNECTION_CLOSE has its read cancelled at GEODE_QUIC_STALL_CANCEL_MS, although another connection from its address stays open" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var stall_env_buf: [64]u8 = undefined;
    const stall_env = try std.fmt.bufPrint(&stall_env_buf, "GEODE_QUIC_STALL_CANCEL_MS={d}", .{vanish_stall_ms});
    var server = try util.spawnServerRandom(allocator, &.{stall_env});
    defer server.deinit();
    const addr = server.getAddr();
    const pid: std.posix.pid_t = server.child.id orelse return error.NoServerPid;
    try seed(allocator, addr, pid);

    // A live client on another connection from the same (loopback) address,
    // idle: its stream sits in the server's read loop the whole time.
    var bystander = try util.QuicProtoClient.connect(allocator, addr);
    defer bystander.deinit();
    var hello_b = try bystander.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello_b.deinit(allocator);

    var gone = try util.QuicProtoClient.connect(allocator, addr);
    var hello = try gone.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);
    startJoin(&gone, pid) catch |err| {
        gone.abandon();
        return err;
    };
    // The client crashes: no CONNECTION_CLOSE, nothing more on the wire.
    const left = nowMillis();
    gone.abandon();

    const idle_ms = idleAfter(pid, left, 75_000);
    if (idle_ms) |ms| {
        std.debug.print("SONNY-6466 (vanish): the server was idle {d} ms after the client vanished (bound {d} ms, stall threshold {d} ms)\n", .{ ms, vanish_idle_deadline_ms, vanish_stall_ms });
    } else {
        std.debug.print("SONNY-6466 (vanish): the server was still busy 75 s after the client vanished\n", .{});
    }
    try testing.expect(idle_ms != null);
    try testing.expect(idle_ms.? <= vanish_idle_deadline_ms);

    // The bystander's connection was not cancelled with it.
    try expectAnswers(allocator, &bystander);
}

/// One QUIC connection carrying several streams (`util.QuicProtoClient` pairs
/// one connection with one stream). A stream wrapper borrows the connection
/// and is released with `releaseStream`, never with `QuicProtoClient.deinit`.
const MuxConn = struct {
    allocator: std.mem.Allocator,
    client: quic.QuicClient,

    fn connect(allocator: std.mem.Allocator, addr: []const u8) !MuxConn {
        const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse return error.InvalidAddress;
        const port = try std.fmt.parseInt(u16, addr[colon + 1 ..], 10);
        var client = quic.QuicClient.init(allocator);
        errdefer client.deinit();
        try client.connectInsecure(addr[0..colon], port, true);
        try client.waitForHandshake(10);
        return .{ .allocator = allocator, .client = client };
    }

    fn openStream(self: *MuxConn) !util.QuicProtoClient {
        const stream = try self.client.openStream(true);
        return .{ .allocator = self.allocator, .client = self.client, .stream = stream };
    }

    fn releaseStream(self: *MuxConn, s: *util.QuicProtoClient) void {
        _ = self;
        s.stream.deinit();
        if (s.session_id.len > 0) s.allocator.free(s.session_id);
        s.session_id = "";
    }
};

// CANARY: REQ=REQ-SONNY-6466-SIBLING-READ-CANCEL-ON-CLOSE; FEATURE="QUIC Abandoned Read Cancellation"; ASPECT=DrainedConnectionCancelsEveryStream; STATUS=TESTED; TEST=tests/test_sonny6466_abandoned_read_cancel.zig; OWNER=transport; UPDATED=2026-11-13
test "SONNY-6466 a client that closes its connection stops a read running on a sibling stream after the first stream ended" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var server = try util.spawnServerRandom(allocator, null);
    defer server.deinit();
    const addr = server.getAddr();
    const pid: std.posix.pid_t = server.child.id orelse return error.NoServerPid;
    try seed(allocator, addr, pid);

    var conn = try MuxConn.connect(allocator, addr);
    var closed = false;
    defer if (!closed) conn.client.closeGraceful(quic.app_error.no_error);

    // The first stream authenticates, answers, and ends: the server hands the
    // connection to its accept reactor.
    var first = try conn.openStream();
    {
        var hello = try first.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer hello.deinit(allocator);
        try testing.expect(hello.success);
        try expectAnswers(allocator, &first);
    }
    conn.releaseStream(&first);
    sleepMillis(250);

    var second = try conn.openStream();
    {
        var hello = try second.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer hello.deinit(allocator);
        try testing.expect(hello.success);
    }
    startJoin(&second, pid) catch |err| {
        conn.releaseStream(&second);
        return err;
    };

    // The client gives up and closes: CONNECTION_CLOSE on the wire.
    const left = nowMillis();
    conn.releaseStream(&second);
    conn.client.closeGraceful(quic.app_error.no_error);
    closed = true;

    const idle_ms = idleAfter(pid, left, 75_000);
    if (idle_ms) |ms| {
        std.debug.print("SONNY-6466 (close, sibling stream): the server was idle {d} ms after the client closed (bound {d} ms)\n", .{ ms, close_idle_deadline_ms });
    } else {
        std.debug.print("SONNY-6466 (close, sibling stream): the server was still busy 75 s after the client closed\n", .{});
    }
    try testing.expect(idle_ms != null);
    try testing.expect(idle_ms.? <= close_idle_deadline_ms);

    var alive = try util.QuicProtoClient.connect(allocator, addr);
    defer alive.deinit();
    var hello2 = try alive.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer hello2.deinit(allocator);
    try testing.expect(hello2.success);
    try expectAnswers(allocator, &alive);
}
