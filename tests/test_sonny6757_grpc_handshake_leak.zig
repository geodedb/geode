// SONNY-6757: every gRPC Handshake leaks its response.
//
// `handleHandshake` (src/transport/grpc_server.zig) built the HelloResponse
// from heap copies (the three capability strings, the capability list, the
// session id and the bound graph name), encoded it, and freed none of them:
// `encodeMessage` copies the bytes it writes. Every gRPC connection leaked
// those allocations for the life of the server, and a Debug server's
// allocator reported them at shutdown.
//
// A real `geode serve` with a gRPC listener answers several Handshakes (one
// with a graph bound) and is then sent SIGTERM. It must exit 0 and its
// allocator must report no allocation made in `handleHandshake` leaked.
//
// CANARY: REQ=REQ-SONNY-6757-GRPC-HANDSHAKE-LEAK; FEATURE="GrpcServerLifecycle"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6757_grpc_handshake_leak.zig; OWNER=transport; UPDATED=2026-11-18

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const testing = std.testing;
const linux = std.os.linux;

const handshakes: usize = 4;

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

test "SONNY-6757: gRPC Handshakes leak nothing at shutdown" {
    // SONNY-6782: plaintext gRPC is served in Debug only.
    if (!util.grpc_plaintext_served) return error.SkipZigTest;
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

    // Authenticated Handshakes, each on its own connection.
    for (0..handshakes) |_| {
        var client = try util.GrpcProtoClient.connect(allocator, grpc_addr);
        defer client.deinit();
        var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(allocator);
        try testing.expect(h.success);
    }
    // One naming a graph (created on demand): the response carries its name.
    {
        var client = try util.GrpcProtoClient.connect(allocator, grpc_addr);
        defer client.deinit();
        var h = try client.helloWithGraph(allocator, util.defaultUsername(), util.defaultPassword(), "sonny6757_g");
        defer h.deinit(allocator);
        try testing.expect(h.success);
    }
    // A refused Handshake (wrong password) returns the capability list too.
    {
        var client = try util.GrpcProtoClient.connect(allocator, grpc_addr);
        defer client.deinit();
        var h = try client.hello(allocator, util.defaultUsername(), "not the password");
        defer h.deinit(allocator);
        try testing.expect(!h.success);
    }

    try std.posix.kill(pid, .TERM);
    const status = waitExit(pid, 30_000);
    if (status != null) handle.child.id = null;
    if (status == null) {
        std.posix.kill(pid, .KILL) catch {};
        _ = waitExit(pid, 10_000);
        handle.child.id = null;
    }

    const log = try std.Io.Dir.cwd().readFileAlloc(io(), log_path, allocator, .limited(256 << 20));
    defer allocator.free(log);
    const handshake_leak = std.mem.indexOf(u8, log, "in handleHandshake") != null;
    std.debug.print("SONNY-6757: exit status {?d}, handleHandshake leak report: {}\n", .{ status, handshake_leak });
    if (status == null or handshake_leak) {
        const at = std.mem.indexOf(u8, log, "leaked:") orelse (if (log.len > 4096) log.len - 4096 else 0);
        const end = @min(log.len, at + 4096);
        std.debug.print("--- server log (from first leak report) ---\n{s}\n--- end ---\n", .{log[at..end]});
    }
    const s = status orelse return error.ShutdownNotWithinDeadline;
    try testing.expect(linux.W.IFEXITED(s) and linux.W.EXITSTATUS(s) == 0);
    try testing.expect(!handshake_leak);
}
