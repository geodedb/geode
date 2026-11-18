// SONNY-6758: the transaction durable undo log is never closed at shutdown.
//
// `server_init.openTxnUndoLog` (src/server/server_init.zig) opens
// `txn_undo.wal` (`txn_durable_undo.Log.open`, src/txn_durable_undo.zig) and
// installs it for the run; nothing uninstalled or closed it. Every clean
// shutdown left its file descriptor, path, cipher and open-transaction set
// allocated, and a Debug server's allocator reported the leak.
//
// A real `geode serve` runs a committed transaction (so the log is written
// and emptied), is sent SIGTERM, and must exit 0 with no allocation made in
// txn_durable_undo.zig reported leaked. A restart on the same data directory
// must then open the log again and find the committed data.
//
// CANARY: REQ=REQ-SONNY-6758-TXN-UNDO-LOG-CLOSE; FEATURE="TransactionManagement"; ASPECT=ShutdownClose; STATUS=TESTED; TEST=tests/test_sonny6758_txn_undo_log_close.zig; OWNER=storage; UPDATED=2026-11-18

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const testing = std.testing;
const linux = std.os.linux;

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

fn connect(allocator: std.mem.Allocator, addr: []const u8) !util.QuicProtoClient {
    var client = try util.QuicProtoClient.connect(allocator, addr);
    errdefer client.deinit();
    var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer h.deinit(allocator);
    if (!h.success) return error.HelloFailed;
    return client;
}

fn quicOk(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !void {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
}

fn quicCount(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !i64 {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
    if (r.rows.len != 1) return error.UnexpectedRows;
    return switch (r.rows[0][0]) {
        .int => |v| v,
        else => error.UnexpectedValue,
    };
}

const Run = struct {
    status: ?u32,
    log: []u8,
};

/// Start `geode serve` on `data_dir`, run `work`, SIGTERM it, and return its
/// exit status and stderr.
fn serveOnce(allocator: std.mem.Allocator, data_dir: []const u8, log_path: []const u8, comptime work: fn (std.mem.Allocator, []const u8) anyerror!void) !Run {
    const addr = try util.formatAddr(allocator, try util.getRandomPort());
    defer allocator.free(addr);
    const cmd = try std.fmt.allocPrint(allocator, "exec '{s}' serve --listen {s} --data-dir '{s}' 2>'{s}'", .{ geode_test_bin.geode_exe, addr, data_dir, log_path });
    defer allocator.free(cmd);
    var handle = try util.spawnServer(allocator, &.{ "/bin/sh", "-c", cmd }, null);
    defer handle.deinit();
    const pid = handle.child.id orelse return error.NoServerPid;
    try util.waitForServerReady(allocator, addr, 60_000);

    try work(allocator, addr);

    try std.posix.kill(pid, .TERM);
    const status = waitExit(pid, 30_000);
    if (status != null) handle.child.id = null;
    if (status == null) {
        std.posix.kill(pid, .KILL) catch {};
        _ = waitExit(pid, 10_000);
        handle.child.id = null;
    }
    const log = try std.Io.Dir.cwd().readFileAlloc(io(), log_path, allocator, .limited(256 << 20));
    return .{ .status = status, .log = log };
}

fn writeCommitted(allocator: std.mem.Allocator, addr: []const u8) !void {
    var client = try connect(allocator, addr);
    defer client.deinit();
    try quicOk(&client, allocator, "CREATE GRAPH s6758");
    try quicOk(&client, allocator, "USE GRAPH s6758");
    var bg = try client.begin(allocator);
    bg.deinit(allocator);
    try quicOk(&client, allocator, "CREATE (:T6758 {i: 1})");
    try quicOk(&client, allocator, "CREATE (:T6758 {i: 2})");
    try testing.expect(try client.commit(allocator));
}

fn readCommitted(allocator: std.mem.Allocator, addr: []const u8) !void {
    var client = try connect(allocator, addr);
    defer client.deinit();
    try quicOk(&client, allocator, "USE GRAPH s6758");
    try testing.expectEqual(@as(i64, 2), try quicCount(&client, allocator, "MATCH (n:T6758) RETURN count(n) AS c"));
}

fn report(label: []const u8, run: Run) bool {
    const undo_leak = std.mem.indexOf(u8, run.log, "txn_durable_undo.zig") != null and
        std.mem.indexOf(u8, run.log, "leaked:") != null;
    std.debug.print("SONNY-6758 {s}: exit status {?d}, txn_durable_undo leak report: {}\n", .{ label, run.status, undo_leak });
    if (run.status == null or undo_leak) {
        const at = std.mem.indexOf(u8, run.log, "txn_durable_undo.zig") orelse (if (run.log.len > 4096) run.log.len - 4096 else 0);
        const from = if (at > 1024) at - 1024 else 0;
        const end = @min(run.log.len, at + 3072);
        std.debug.print("--- server log ---\n{s}\n--- end ---\n", .{run.log[from..end]});
    }
    return undo_leak;
}

test "SONNY-6758: a clean shutdown closes the transaction undo log" {
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

    const first = try serveOnce(allocator, data_dir, log_path, writeCommitted);
    defer allocator.free(first.log);
    const first_leak = report("first run", first);
    const s1 = first.status orelse return error.ShutdownNotWithinDeadline;
    try testing.expect(linux.W.IFEXITED(s1) and linux.W.EXITSTATUS(s1) == 0);
    try testing.expect(!first_leak);

    // The closed log reopens; the committed transaction is all there.
    const second = try serveOnce(allocator, data_dir, log_path, readCommitted);
    defer allocator.free(second.log);
    const second_leak = report("restart", second);
    const s2 = second.status orelse return error.ShutdownNotWithinDeadline;
    try testing.expect(linux.W.IFEXITED(s2) and linux.W.EXITSTATUS(s2) == 0);
    try testing.expect(!second_leak);
}
