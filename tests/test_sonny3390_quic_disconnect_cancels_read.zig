// SONNY-3390: a QUIC client that disconnects must stop the read it left
// running promptly, not after the per-connection stall watchdog (60 s).
//
// A read's cancel source is the stream's connection-level
// `shutdown_requested` flag (quic_connection_handler.zig: the read budget's
// `setStreamCancelSource` and the node scan's `cancel_token`). Nothing set it
// while a handler was executing on a connection whose peer had closed, so an
// abandoned comma join kept a server core busy until the stall watchdog marked
// the connection's readers cancelled at 60 s.
//
// The test drives a real `geode serve` over real QUIC: it seeds a graph, sends
// (with no statement timeout) a comma join whose WHERE keeps no binding
// (400^3 bindings, minutes of work), and after 1 s closes the connection
// (CONNECTION_CLOSE on the wire). The server's CPU time (/proc/<pid>/stat)
// must fall to idle well inside the watchdog threshold, and the server must
// still answer a new connection. (A client that vanishes WITHOUT a
// CONNECTION_CLOSE cannot be seen before the QUIC idle timeout; that bound is
// the transport's idle timeout and the stall watchdog, not this fix.)

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const schema = @import("schema");

/// A comma join no binding of which survives its WHERE: 400^3 = 64 million
/// bindings, each evaluated, so it runs for minutes and returns nothing.
const join_query = "MATCH (a:KP), (c:KP), (d:KP) WHERE a.i + c.i + d.i < 0 RETURN a.i";

/// Well below the 60 s stall watchdog, with room for a loaded machine.
const idle_deadline_ms: i64 = 20_000;

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

/// SONNY-6923: real CPU contention, the way a loaded CI runner starved the
/// server in main pipeline 3099257214 (31 ticks a second for the join):
/// every server thread is pinned to one CPU, and two busy threads of this
/// process run on the same CPU, so the scheduler gives the server about a
/// third of a core.
const Contention = struct {
    const hogs = 2;
    cpu: usize,
    stop: std.atomic.Value(bool) = .init(false),
    threads: [hogs]std.Thread = undefined,

    fn oneCpu(cpu: usize) std.os.linux.cpu_set_t {
        var set = std.mem.zeroes(std.os.linux.cpu_set_t);
        set[cpu / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize));
        return set;
    }

    /// Pin every thread `pid` has now. Threads it starts later inherit the
    /// mask of the thread that starts them.
    fn pinProcess(self: *const Contention, pid: std.posix.pid_t) !void {
        const set = oneCpu(self.cpu);
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/task", .{pid});
        const io = std.Io.Threaded.global_single_threaded.io();
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        var pinned: usize = 0;
        while (try it.next(io)) |entry| {
            const tid = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch continue;
            std.os.linux.sched_setaffinity(tid, &set) catch continue;
            pinned += 1;
        }
        if (pinned == 0) return error.NoServerThreadPinned;
    }

    fn hog(self: *Contention) void {
        const set = oneCpu(self.cpu);
        std.os.linux.sched_setaffinity(0, &set) catch return;
        var x: u64 = 0;
        while (!self.stop.load(.monotonic)) x +%= 1;
        std.mem.doNotOptimizeAway(x);
    }

    fn start(self: *Contention) !void {
        for (&self.threads) |*t| t.* = try std.Thread.spawn(.{}, hog, .{self});
    }

    fn finish(self: *Contention) void {
        self.stop.store(true, .release);
        for (self.threads) |t| t.join();
    }
};

test "SONNY-3390 a QUIC client that closes its connection stops its running read well before the 60 s stall watchdog" {
    try runDisconnectScenario(false);
}

test "SONNY-6923 the disconnect is detected on a server starved of CPU" {
    try runDisconnectScenario(true);
}

fn runDisconnectScenario(starved: bool) !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var server = try util.spawnServerRandom(allocator, null);
    defer server.deinit();
    const addr = server.getAddr();
    const server_pid: std.posix.pid_t = server.child.id orelse return error.NoServerPid;

    {
        var client = try util.QuicProtoClient.connect(allocator, addr);
        defer client.deinit();
        var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        hello.deinit(allocator);
        var seeded = try client.executeAndCollectWithTimeout(allocator, "FOR i IN range(1, 400) CREATE (:KP {i: i})-[:KE]->(:KP2 {i: i})", util.emptyParams(), 1000, 120);
        const failed = seeded.error_code != null;
        seeded.deinit(allocator);
        if (failed) return error.SeedFailed;
    }

    // A starved server is starved throughout, at rest as when busy, as on
    // the loaded runner.
    var contention: Contention = .{ .cpu = 0 };
    var contended = false;
    if (starved) {
        try contention.pinProcess(server_pid);
        try contention.start();
        contended = true;
    }
    defer if (contended) contention.finish();
    // Let the server settle after the seed (persistence, index work): at
    // rest it spends well under 30 ticks a second.
    var rest_ticks: u64 = 0;
    {
        const settle_start = nowMillis();
        var prev = procCpuTicks(server_pid);
        var settled = false;
        while (nowMillis() - settle_start < 60_000) {
            sleepMillis(1_000);
            const now_t = procCpuTicks(server_pid);
            if (now_t -| prev < 30) {
                settled = true;
                rest_ticks = now_t -| prev;
                prev = now_t;
                break;
            }
            prev = now_t;
        }
        if (!settled) std.debug.print("SONNY-3390: the server never went idle after the seed\n", .{});
        try testing.expect(settled);
        // SONNY-6923: the first quiet second can still carry the tail of the
        // seed's work; the rest rate is the quietest of the next three.
        var k: usize = 0;
        while (k < 3) : (k += 1) {
            sleepMillis(1_000);
            const now_t = procCpuTicks(server_pid);
            rest_ticks = @min(rest_ticks, now_t -| prev);
            prev = now_t;
        }
    }

    var client = try util.QuicProtoClient.connect(allocator, addr);
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);
    var client_open = true;
    defer if (client_open) client.deinit();
    // Send the statement with no statement timeout (a timeout makes the
    // server cancel it itself) and never read the answer: the client simply
    // goes away, as one that gives up on a slow query does.
    try client.writeMessage(.{ .execute = schema.ExecuteRequest{
        .session_id = client.session_id,
        .query = join_query,
        .params = .empty,
    } });
    sleepMillis(1_000);
    // The query is running: the server is busy.
    const busy_from = procCpuTicks(server_pid);
    sleepMillis(1_000);
    const busy_ticks = procCpuTicks(server_pid) -| busy_from;
    // SONNY-6923: how much CPU the join gets depends on the host (a loaded
    // runner gave it 31 ticks a second), so "running" means clearly busier
    // than at rest, and "idle again" is judged against what it got.
    const running = busy_ticks >= 50;
    if (!running) std.debug.print("SONNY-3390: the join spent only {d} ticks in its second second (at rest {d})\n", .{ busy_ticks, rest_ticks });
    try testing.expect(running);
    const idle_ticks: u64 = 30;

    // Close the connection: CONNECTION_CLOSE on the wire (what a client that
    // gives up and closes sends), then free the client.
    const left = nowMillis();
    client_open = false;
    client.deinit();

    var idle_after: ?i64 = null;
    var prev = procCpuTicks(server_pid);
    while (nowMillis() - left < 75_000) {
        sleepMillis(1_000);
        const now_t = procCpuTicks(server_pid);
        if (now_t -| prev < idle_ticks) {
            idle_after = nowMillis() - left;
            break;
        }
        prev = now_t;
    }
    if (idle_after) |ms| {
        std.debug.print("SONNY-3390: the server was idle {d} ms after the client left (bound {d} ms)\n", .{ ms, idle_deadline_ms });
    } else {
        std.debug.print("SONNY-3390: the server was still busy 75 s after the client left\n", .{});
    }
    try testing.expect(idle_after != null);
    try testing.expect(idle_after.? <= idle_deadline_ms);
    if (contended) {
        contention.finish();
        contended = false;
    }

    var alive = try util.QuicProtoClient.connect(allocator, addr);
    defer alive.deinit();
    var hello2 = try alive.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer hello2.deinit(allocator);
    try testing.expect(hello2.success);
    var one = try alive.executeAndCollectWithTimeout(allocator, "RETURN 1 AS one", util.emptyParams(), 1000, 30);
    defer one.deinit(allocator);
    try testing.expect(one.error_code == null);
    try testing.expectEqual(@as(usize, 1), one.rows.len);
}
