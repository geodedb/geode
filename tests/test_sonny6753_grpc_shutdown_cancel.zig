// SONNY-6753: SIGTERM does not cancel an in-flight gRPC statement.
//
// A gRPC handler never installed a cancel source for the read executor
// (`read_budget.setStreamCancelSource`); only the QUIC handler did. So at
// shutdown the QUIC path cancels its statements (the transport sets each
// connection's `shutdown_requested`, the executor's row polls see it and
// abort with 57014), while a gRPC statement ran on to completion. The shutdown
// tail then sat in `waitForGrpcInflightZero` for the full drain timeout
// (30 s), gave up, skipped the store free, and the teardown either reached the
// allocator leak check with the statement's working set still allocated (the
// DebugAllocator leak report of `materializeNode` rows seen in
// test-grpc-shutdown-drain) or waited for the teardown watchdog. Under load
// that exceeded test-grpc-shutdown-drain's 90 s deadline.
//
// A real `geode serve` runs a 3-way cartesian (200 nodes, 8M combinations,
// over a minute in Debug) over gRPC and is sent SIGTERM while it runs. The
// statement must be cancelled: the gRPC drain completes, the server exits 0
// well inside the 30 s drain timeout, the store is freed and nothing is
// reported leaked, the teardown watchdog does not fire,
// and the client is not told the statement succeeded with an empty result.
//
// CANARY: REQ=REQ-SONNY-6753-GRPC-SHUTDOWN-CANCEL; FEATURE="GrpcServerLifecycle"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6753_grpc_shutdown_cancel.zig; OWNER=transport; UPDATED=2026-11-18

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const testing = std.testing;
const linux = std.os.linux;

const grpc_query_transport = geode.grpc_query_transport;
const query_runner = geode.query_runner;

/// Well under the 30 s gRPC drain timeout: a cancelled statement unwinds
/// within one row, so the whole shutdown takes a few seconds.
const exit_deadline_ms: i64 = 20_000;
const slow_rows: usize = 200;
const inflight_settle_ms: u64 = 6_000;
const slow_statement = "MATCH (a:SlowP), (b:SlowP), (c:SlowP) RETURN count(*) AS c";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowMs() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
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
        io().sleep(.fromMilliseconds(50), .awake) catch {};
    }
    return null;
}

/// The slow statement, run over the real gRPC listener on its own thread.
const SlowQuery = struct {
    addr: []const u8,
    done: std.atomic.Value(bool) = .init(false),
    /// Outcome, valid once `done`.
    transport_error: ?anyerror = null,
    has_error: bool = false,
    status_class: [5]u8 = "?????".*,
    row_count: usize = 0,

    fn run(self: *SlowQuery) void {
        defer self.done.store(true, .release);
        self.runInner() catch |err| {
            self.transport_error = err;
        };
    }

    fn runInner(self: *SlowQuery) !void {
        const allocator = std.heap.smp_allocator;
        var client = try util.GrpcProtoClient.connect(allocator, self.addr);
        defer client.deinit();
        var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(allocator);
        if (!h.success) return error.AuthenticationFailed;

        var adapter = grpc_query_transport.StreamingQueryAdapter{ .stream = client.stream, .stream_ids = &client.stream_ids };
        var transport = adapter.asTransport();
        var result = try query_runner.collectQueryWithTransport(allocator, &transport, .{
            .session_id = client.session_id,
            .query_text = slow_statement,
            .format = "json",
            .timeout_secs = 300,
            .page_size = 1000,
            .params = util.emptyParams(),
        });
        defer result.deinit();
        self.has_error = result.indicatesFailure();
        const n = @min(result.status_class.len, self.status_class.len);
        @memcpy(self.status_class[0..n], result.status_class[0..n]);
        self.row_count = result.rowCount();
    }
};

fn seed(allocator: std.mem.Allocator, addr: []const u8) !void {
    var stmt = std.ArrayList(u8).empty;
    defer stmt.deinit(allocator);
    try stmt.appendSlice(allocator, "CREATE ");
    for (0..slow_rows) |i| {
        if (i != 0) try stmt.appendSlice(allocator, ", ");
        var buf: [64]u8 = undefined;
        try stmt.appendSlice(allocator, try std.fmt.bufPrint(&buf, "(:SlowP {{i: {d}}})", .{i}));
    }
    var client = try util.GrpcProtoClient.connect(allocator, addr);
    defer client.deinit();
    var res = try client.executeAndCollect(allocator, stmt.items, util.emptyParams(), 1000);
    defer res.deinit(allocator);
    if (res.error_code) |code| {
        std.debug.print("seed failed: {s} {s}\n", .{ code, res.error_message orelse "" });
        return error.SeedFailed;
    }
}

test "SONNY-6753: SIGTERM cancels an in-flight gRPC statement; prompt drain, no leak, no watchdog" {
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

    try seed(allocator, grpc_addr);

    var q = SlowQuery{ .addr = grpc_addr };
    const qt = try std.Thread.spawn(.{}, SlowQuery.run, .{&q});
    var joined = false;
    defer if (!joined) qt.join();

    io().sleep(.fromMilliseconds(inflight_settle_ms), .awake) catch {};
    if (q.done.load(.acquire)) {
        std.debug.print("SONNY-6753: the {d}-row cartesian finished inside {d} ms (error {?}); nothing was in flight\n", .{ slow_rows, inflight_settle_ms, q.transport_error });
        return error.SlowProbeWasNotSlow;
    }

    const t0 = nowMs();
    try std.posix.kill(pid, .TERM);
    const status = waitExit(pid, exit_deadline_ms);
    const took = nowMs() - t0;
    if (status != null) handle.child.id = null;
    // Unblock the client if the server is still up (SIGKILL; the socket closes).
    if (status == null) {
        std.posix.kill(pid, .KILL) catch {};
        _ = waitExit(pid, 10_000);
        handle.child.id = null;
    }
    qt.join();
    joined = true;

    const log = try std.Io.Dir.cwd().readFileAlloc(io(), log_path, allocator, .limited(256 << 20));
    defer allocator.free(log);
    const drained = std.mem.indexOf(u8, log, "gRPC handler drain complete") != null;
    const left_in_flight = std.mem.indexOf(u8, log, "still in flight after") != null;
    // The statement's working set and the store must both be freed, and
    // nothing else may be reported leaked either (SONNY-6757 and SONNY-6758
    // fixed the gRPC Handshake response and txn undo log leaks this check
    // used to leave out).
    const leaked = std.mem.indexOf(u8, log, "leaked:") != null;
    const store_skipped = std.mem.indexOf(u8, log, "skipping global store free") != null;
    const watchdog = std.mem.indexOf(u8, log, "teardown watchdog: forcing process exit") != null;
    const empty_success = q.transport_error == null and !q.has_error and q.row_count == 0;
    std.debug.print(
        "SONNY-6753: shutdown took {d} ms, exit status {?d}, grpc drain complete: {}, left in flight: {}, leak report: {}, store free skipped: {}, watchdog exit: {}; client: error {?}, failed {}, status {s}, rows {d}\n",
        .{ took, status, drained, left_in_flight, leaked, store_skipped, watchdog, q.transport_error, q.has_error, &q.status_class, q.row_count },
    );
    if (status == null or !drained or left_in_flight or leaked or store_skipped or watchdog or empty_success) {
        const tail = if (log.len > 4096) log[log.len - 4096 ..] else log;
        std.debug.print("--- server log (tail) ---\n{s}\n--- end ---\n", .{tail});
    }
    const s = status orelse return error.ShutdownNotWithinDeadline;
    try testing.expect(linux.W.IFEXITED(s) and linux.W.EXITSTATUS(s) == 0);
    try testing.expect(drained);
    try testing.expect(!left_in_flight);
    try testing.expect(!leaked);
    try testing.expect(!store_skipped);
    try testing.expect(!watchdog);
    try testing.expect(!empty_success);
}
