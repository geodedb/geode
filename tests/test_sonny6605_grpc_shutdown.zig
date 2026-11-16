// SONNY-6605 (3): a server started with both --listen and --listen-grpc
// stops its gRPC accept loop at shutdown; the pool that runs it joins at
// once, and the teardown watchdog does not have to force the exit.
//
// `geode serve --listen ... --listen-grpc ...` runs the gRPC listener's
// accept loop (grpc-zig `GrpcServer.start`, a `while (true)` around a
// blocking accept) as the one task of a one-thread pool. Nothing stopped the
// loop: at shutdown the pool's deinit waited its 2 s drain timeout ("thread-
// pool deinit timed out after 2000ms with 1 active tasks"), then joined the
// worker, which never returned, and the 30 s teardown watchdog forced the
// exit (seen in test-sonny6591-fts-write-paths). Now the shutdown tail shuts
// the listening socket down, accept fails, the loop returns, and the pool
// joins.
//
// A real `geode serve` is started, answers a gRPC and a QUIC hello, and
// is sent SIGTERM; it must exit 0 well inside the watchdog's 30 s, with no
// pool deinit timeout and no watchdog exit in its log.
//
// CANARY: REQ=REQ-SONNY-6605-GRPC-ACCEPT-STOP; FEATURE="GrpcServerLifecycle"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6605_grpc_shutdown.zig; OWNER=transport; UPDATED=2026-11-15

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const testing = std.testing;
const linux = std.os.linux;

/// The teardown watchdog forces the exit 30 s after the data flush; a
/// shutdown with nothing in flight takes a few seconds.
const exit_deadline_ms: i64 = 20_000;

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

/// Wait for `pid` to exit; its exit status, or null at the deadline.
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

test "SONNY-6605 (3): SIGTERM stops the gRPC accept loop; no pool join timeout, no watchdog exit" {
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

    // Both listeners serve.
    {
        var client = try util.QuicProtoClient.connect(allocator, addr);
        defer client.deinit();
        var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(allocator);
        try testing.expect(h.success);
    }
    {
        var grpc = try util.GrpcProtoClient.connect(allocator, grpc_addr);
        defer grpc.deinit();
        var h = try grpc.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(allocator);
        try testing.expect(h.success);
    }

    const t0 = nowMs();
    try std.posix.kill(pid, .TERM);
    const status = waitExit(pid, exit_deadline_ms);
    const took = nowMs() - t0;
    if (status != null) handle.child.id = null;

    const log = try std.Io.Dir.cwd().readFileAlloc(io(), log_path, allocator, .limited(64 << 20));
    defer allocator.free(log);
    const timed_out = std.mem.indexOf(u8, log, "thread-pool deinit timed out") != null;
    const watchdog = std.mem.indexOf(u8, log, "teardown watchdog: forcing process exit") != null;
    std.debug.print("SONNY-6605 (3): shutdown took {d} ms, exit status {?d}, pool deinit timeout: {}, watchdog exit: {}\n", .{ took, status, timed_out, watchdog });
    if (status == null or timed_out or watchdog) {
        const tail = if (log.len > 4096) log[log.len - 4096 ..] else log;
        std.debug.print("--- server log (tail) ---\n{s}\n--- end ---\n", .{tail});
    }
    const s = status orelse return error.ShutdownNotWithinDeadline;
    try testing.expect(linux.W.IFEXITED(s) and linux.W.EXITSTATUS(s) == 0);
    try testing.expect(!timed_out);
    try testing.expect(!watchdog);
}
