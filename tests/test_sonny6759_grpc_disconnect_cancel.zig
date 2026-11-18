// SONNY-6759: a gRPC statement keeps running after its client disconnects.
//
// The QUIC handler installs its connection's `shutdown_requested` flag as
// the executor's statement cancel source, so a client that closes its
// connection cancels its statement (SONNY-3390). The gRPC handler's only
// cancel source was the server-wide shutdown flag (SONNY-6753): a client that
// closed its TCP connection, or reset the statement's HTTP/2 stream
// (RST_STREAM), left the statement running to completion, holding a core and
// its working set for minutes.
//
// A real `geode serve` with a gRPC listener runs, over gRPC, a comma join no
// binding of which survives its WHERE (minutes of work). Case 1: the client
// closes its TCP connection. Case 2: the client sends RST_STREAM (CANCEL) for
// the statement's stream and keeps the connection open. In each case the
// server's CPU time (/proc/<pid>/stat) must fall to idle within 20 s, and the
// server must still answer a new gRPC connection. A SIGTERM at the end must
// still exit 0 (the shutdown flag still cancels).
//
// CANARY: REQ=REQ-SONNY-6759-GRPC-DISCONNECT-CANCEL; FEATURE="GrpcServerLifecycle"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6759_grpc_disconnect_cancel.zig; OWNER=transport; UPDATED=2026-11-18

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const testing = std.testing;
const linux = std.os.linux;

const grpc_query_transport = geode.grpc_query_transport;
const query_runner = geode.query_runner;

/// 400^3 = 64 million bindings, each evaluated, none kept: minutes of work.
const join_query = "MATCH (a:KP), (c:KP), (d:KP) WHERE a.i + c.i + d.i < 0 RETURN a.i";
const idle_deadline_ms: i64 = 20_000;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowMs() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: i64) void {
    io().sleep(.fromMilliseconds(ms), .awake) catch {};
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn waitExit(pid: std.posix.pid_t, deadline_ms: i64) ?u32 {
    const t0 = nowMs();
    while (nowMs() - t0 < deadline_ms) {
        var status: u32 = 0;
        const rc: isize = @bitCast(linux.waitpid(pid, &status, linux.W.NOHANG));
        if (rc == pid) return status;
        if (rc < 0) return null;
        sleepMs(50);
    }
    return null;
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

/// Milliseconds until the server spends under 30 ticks in a second, or null
/// if it stays busy for `limit_ms`.
fn idleWithin(pid: std.posix.pid_t, limit_ms: i64) ?i64 {
    const t0 = nowMs();
    var prev = procCpuTicks(pid);
    while (nowMs() - t0 < limit_ms) {
        sleepMs(1_000);
        const now_t = procCpuTicks(pid);
        if (now_t -| prev < 30) return nowMs() - t0;
        prev = now_t;
    }
    return null;
}

/// The join, run over the real gRPC listener on its own thread. The client
/// is set up (connected, authenticated) before the thread starts, so the
/// test knows the socket and the statement's stream id.
const SlowQuery = struct {
    client: util.GrpcProtoClient,
    /// The HTTP/2 stream id the statement's Execute takes.
    stream_id: u31 = 0,
    done: std.atomic.Value(bool) = .init(false),

    fn start(allocator: std.mem.Allocator, addr: []const u8) !*SlowQuery {
        const self = try allocator.create(SlowQuery);
        errdefer allocator.destroy(self);
        self.* = .{ .client = try util.GrpcProtoClient.connect(allocator, addr) };
        errdefer self.client.deinit();
        var h = try self.client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(allocator);
        if (!h.success) return error.AuthenticationFailed;
        self.stream_id = @intCast(self.client.stream_ids.next);
        return self;
    }

    fn run(self: *SlowQuery) void {
        defer self.done.store(true, .release);
        const allocator = std.heap.smp_allocator;
        var adapter = grpc_query_transport.StreamingQueryAdapter{ .stream = self.client.stream, .stream_ids = &self.client.stream_ids };
        var transport = adapter.asTransport();
        var result = query_runner.collectQueryWithTransport(allocator, &transport, .{
            .session_id = self.client.session_id,
            .query_text = join_query,
            .format = "json",
            .timeout_secs = 600,
            .page_size = 1000,
            .params = util.emptyParams(),
        }) catch return;
        result.deinit();
    }

    fn socket(self: *SlowQuery) std.posix.fd_t {
        return self.client.stream.socket.handle;
    }

    /// Unblock the query thread (shut the socket down), join it, free.
    fn finish(self: *SlowQuery, allocator: std.mem.Allocator, thread: std.Thread) void {
        _ = std.c.shutdown(self.socket(), 2);
        thread.join();
        self.client.deinit();
        allocator.destroy(self);
    }
};

/// An HTTP/2 RST_STREAM frame (type 0x3) with error code CANCEL (0x8).
fn rstStreamFrame(stream_id: u31) [13]u8 {
    var f: [13]u8 = undefined;
    f[0] = 0;
    f[1] = 0;
    f[2] = 4;
    f[3] = 0x3;
    f[4] = 0;
    std.mem.writeInt(u32, f[5..9], @as(u32, stream_id), .big);
    std.mem.writeInt(u32, f[9..13], 0x8, .big);
    return f;
}

fn seed(allocator: std.mem.Allocator, addr: []const u8) !void {
    var client = try util.GrpcProtoClient.connect(allocator, addr);
    defer client.deinit();
    var res = try client.executeAndCollect(allocator, "FOR i IN range(1, 400) CREATE (:KP {i: i})", util.emptyParams(), 1000);
    defer res.deinit(allocator);
    if (res.error_code) |code| {
        std.debug.print("seed failed: {s} {s}\n", .{ code, res.error_message orelse "" });
        return error.SeedFailed;
    }
}

fn expectServerAnswers(allocator: std.mem.Allocator, addr: []const u8) !void {
    var client = try util.GrpcProtoClient.connect(allocator, addr);
    defer client.deinit();
    var res = try client.executeAndCollect(allocator, "RETURN 1 AS one", util.emptyParams(), 1000);
    defer res.deinit(allocator);
    try testing.expect(res.error_code == null);
    try testing.expectEqual(@as(usize, 1), res.rows.len);
}

const Leave = enum { close_connection, reset_stream };

/// Start the join, confirm the server is busy with it, leave as `how`, and
/// return how long the server took to go idle (null: still busy at 75 s).
fn runCase(allocator: std.mem.Allocator, addr: []const u8, pid: std.posix.pid_t, how: Leave) !?i64 {
    const q = try SlowQuery.start(allocator, addr);
    const thread = try std.Thread.spawn(.{}, SlowQuery.run, .{q});
    defer q.finish(allocator, thread);

    sleepMs(1_500);
    const busy_from = procCpuTicks(pid);
    sleepMs(1_000);
    const busy = procCpuTicks(pid) -| busy_from;
    if (busy < 50 or q.done.load(.acquire)) {
        std.debug.print("SONNY-6759 {s}: the join was not running (ticks {d}, done {})\n", .{ @tagName(how), busy, q.done.load(.acquire) });
        return error.SlowProbeWasNotSlow;
    }

    switch (how) {
        // FIN to the server; the query thread's read then fails and returns.
        .close_connection => _ = std.c.shutdown(q.socket(), 2),
        // The connection stays open; only the statement's stream is reset.
        .reset_stream => {
            const frame = rstStreamFrame(q.stream_id);
            const wrote = std.c.write(q.socket(), &frame, frame.len);
            if (wrote != frame.len) return error.RstStreamWriteFailed;
        },
    }
    const idle = idleWithin(pid, 75_000);
    if (idle) |ms| {
        std.debug.print("SONNY-6759 {s}: the server was idle {d} ms after the client left (bound {d} ms)\n", .{ @tagName(how), ms, idle_deadline_ms });
    } else {
        std.debug.print("SONNY-6759 {s}: the server was still busy 75 s after the client left\n", .{@tagName(how)});
    }
    return idle;
}

test "SONNY-6759: a gRPC client that disconnects or resets its stream cancels its statement" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(base);
    const data_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{base});
    defer allocator.free(data_dir);
    const log_path = try std.fmt.allocPrint(allocator, "{s}/server.log", .{base});
    defer allocator.free(log_path);
    try std.Io.Dir.cwd().createDirPath(io(), data_dir);

    const addr = try util.formatAddr(allocator, try util.getRandomPort());
    defer allocator.free(addr);
    const grpc_addr = try util.formatAddr(allocator, try util.getRandomTcpPort());
    defer allocator.free(grpc_addr);
    const cmd = try std.fmt.allocPrint(allocator, "exec '{s}' serve --listen {s} --listen-grpc {s} --data-dir '{s}' 2>>'{s}'", .{ geode_test_bin.geode_exe, addr, grpc_addr, data_dir, log_path });
    defer allocator.free(cmd);

    var handle = try util.spawnServer(allocator, &.{ "/bin/sh", "-c", cmd }, &.{"GEODE_GRPC_ALLOW_PLAINTEXT_FALLBACK=1"});
    defer handle.deinit();
    const pid = handle.child.id orelse return error.NoServerPid;
    try util.waitForServerReady(allocator, addr, 60_000);
    try util.waitForGrpcServerReady(allocator, grpc_addr, 30_000);

    try seed(allocator, grpc_addr);
    if (idleWithin(pid, 60_000) == null) return error.ServerNeverIdleAfterSeed;

    const closed = try runCase(allocator, grpc_addr, pid, .close_connection);
    try expectServerAnswers(allocator, grpc_addr);
    const reset = try runCase(allocator, grpc_addr, pid, .reset_stream);
    try expectServerAnswers(allocator, grpc_addr);

    // The shutdown flag still cancels: SIGTERM exits 0.
    try std.posix.kill(pid, .TERM);
    const status = waitExit(pid, 30_000);
    if (status != null) handle.child.id = null;

    try testing.expect(closed != null and closed.? <= idle_deadline_ms);
    try testing.expect(reset != null and reset.? <= idle_deadline_ms);
    const s = status orelse return error.ShutdownNotWithinDeadline;
    try testing.expect(linux.W.IFEXITED(s) and linux.W.EXITSTATUS(s) == 0);
}
