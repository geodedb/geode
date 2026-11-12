// CANARY: REQ=REQ-SONNY-6374-LSP-AUTH-PROVIDER-LIFETIME; FEATURE="Embedded LSP"; ASPECT=AuthProviderOutlivesSessions; STATUS=TESTED; TEST=tests/test_sonny6374_lsp_auth_provider_lifetime.zig; OWNER=lsp; UPDATED=2026-11-12
//
// SONNY-6374 (1): `geode serve` allocated the embedded LSP listener's
// AuthProvider inside an `if` block and registered the `defer` that frees it
// in the same block, so the provider was freed as soon as the listener thread
// had been spawned. Every LSP session then verified its `initialize` token
// through a verifier that pointed at freed memory: a use-after-free on the
// authentication path of every embedded LSP session.
//
// The debug server runs on DebugAllocator, which overwrites freed memory with
// 0xAA. The provider's mutex then reads as locked-and-contended, so the first
// `initialize` with a token blocks forever on it and the session never
// answers. These tests drive the real server binary over TCP:
//   (a) two sessions in a row each get the JSON-RPC -32002 "invalid auth
//       token" answer for a token no provider issued;
//   (b) on SIGTERM with a session still connected, the server closes the
//       session, stops the listener, frees the provider, and exits 0 with no
//       leak report.
const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const test_ports = @import("test_ports.zig");
const scratch = @import("test_scratch.zig");

const testing = std.testing;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn sleepMs(ms: u64) void {
    io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

fn monoMs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

const LoggedServer = struct {
    handle: util.ServerHandle,
    dir: scratch.ScratchDir,
    log_path: []u8,

    /// `geode serve` with stdout and stderr in a file of its scratch dir and
    /// the embedded LSP listener on `lsp_port`.
    fn start(allocator: std.mem.Allocator, lsp_port: u16) !LoggedServer {
        var dir = try scratch.ScratchDir.create("sonny6374");
        errdefer dir.remove();
        const data_dir = try std.fs.path.join(allocator, &.{ dir.path(), "data" });
        defer allocator.free(data_dir);
        try std.Io.Dir.cwd().createDirPath(io(), data_dir);
        const log_path = try std.fs.path.join(allocator, &.{ dir.path(), "server.log" });
        errdefer allocator.free(log_path);

        const quic_port = try test_ports.freeUdpPortExcept(&.{lsp_port});
        var listen_buf: [32]u8 = undefined;
        const listen = try std.fmt.bufPrint(&listen_buf, "127.0.0.1:{d}", .{quic_port});
        var lsp_buf: [8]u8 = undefined;
        const lsp_env = try std.fmt.bufPrint(&lsp_buf, "{d}", .{lsp_port});

        var map = try std.Io.Threaded.global_single_threaded.environ.process_environ.createMap(allocator);
        errdefer map.deinit();
        try map.put("GEODE_ADMIN_USERNAME", util.DefaultAuth.username);
        try map.put("GEODE_ADMIN_PASSWORD", util.DefaultAuth.password);
        // The build sets GEODE_LSP_PORT=0 for every geode-spawning test
        // (SONNY-6332); this test needs the listener, on a port of its own.
        try map.put("GEODE_LSP_PORT", lsp_env);

        const argv = [_][]const u8{ geode_test_bin.geode_exe, "serve", "--listen", listen, "--data-dir", data_dir, "--log-level=info" };

        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        errdefer threaded.deinit();
        const log_file = try std.Io.Dir.cwd().createFile(io(), log_path, .{});
        defer log_file.close(io());
        const child = try std.process.spawn(threaded.io(), .{
            .argv = &argv,
            .environ_map = &map,
            .stdin = .ignore,
            .stdout = .{ .file = log_file },
            .stderr = .{ .file = log_file },
        });
        return .{
            .handle = .{ .allocator = allocator, .threaded = threaded, .child = child, .env_map = map },
            .dir = dir,
            .log_path = log_path,
        };
    }

    fn log(self: *const LoggedServer, allocator: std.mem.Allocator) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(io(), self.log_path, allocator, .limited(64 << 20));
    }

    fn printLog(self: *const LoggedServer, allocator: std.mem.Allocator) void {
        if (self.log(allocator)) |text| {
            defer allocator.free(text);
            std.debug.print("SONNY-6374: server log:\n{s}\n", .{text});
        } else |_| {}
    }

    /// Wait until the log contains `needle`; error.Timeout after `ms`.
    fn waitForLog(self: *const LoggedServer, allocator: std.mem.Allocator, needle: []const u8, ms: u64) !void {
        const deadline = monoMs() + ms;
        while (monoMs() < deadline) {
            const text = try self.log(allocator);
            defer allocator.free(text);
            if (std.mem.indexOf(u8, text, needle) != null) return;
            sleepMs(100);
        }
        std.debug.print("SONNY-6374: no \"{s}\" within {d} ms\n", .{ needle, ms });
        self.printLog(allocator);
        return error.Timeout;
    }

    fn stop(self: *LoggedServer, allocator: std.mem.Allocator) void {
        self.handle.deinit();
        allocator.free(self.log_path);
        self.dir.remove();
    }
};

/// The whole of a procfs file. procfs reports size 0, so `readFileAlloc`
/// and a positional `File.reader` (both size the read from stat) return an
/// empty buffer; a streaming reader reads to EOF.
fn readProcFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io(), path, .{});
    defer file.close(io());
    var buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io(), &buf);
    return reader.interface.allocRemaining(allocator, .limited(64 << 20));
}

/// The TCP ports process `pid` listens on: its socket inodes (from
/// /proc/<pid>/fd) matched against the LISTEN rows of /proc/net/tcp{,6}.
/// Read from the kernel rather than the server's log, and without
/// connecting to anything another process may own.
fn listeningTcpPorts(allocator: std.mem.Allocator, pid: std.posix.pid_t) !std.ArrayList(u16) {
    var inodes: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer inodes.deinit(allocator);
    var fd_path_buf: [64]u8 = undefined;
    const fd_dir_path = try std.fmt.bufPrint(&fd_path_buf, "/proc/{d}/fd", .{pid});
    var fd_dir = try std.Io.Dir.cwd().openDir(io(), fd_dir_path, .{ .iterate = true });
    defer fd_dir.close(io());
    var it = fd_dir.iterate();
    while (try it.next(io())) |entry| {
        var link_buf: [128]u8 = undefined;
        const n = fd_dir.readLink(io(), entry.name, &link_buf) catch continue;
        const link = link_buf[0..n];
        const prefix = "socket:[";
        if (!std.mem.startsWith(u8, link, prefix) or link.len < prefix.len + 2) continue;
        const inode = std.fmt.parseUnsigned(u64, link[prefix.len .. link.len - 1], 10) catch continue;
        try inodes.put(allocator, inode, {});
    }

    var ports: std.ArrayList(u16) = .empty;
    errdefer ports.deinit(allocator);
    for ([_][]const u8{ "/proc/net/tcp", "/proc/net/tcp6" }) |table| {
        // A host without IPv6 has no tcp6 table; tcp must be readable.
        const text = readProcFile(allocator, table) catch |err| switch (err) {
            error.FileNotFound => if (std.mem.endsWith(u8, table, "6")) continue else return err,
            else => return err,
        };
        defer allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        _ = lines.next(); // header
        while (lines.next()) |line| {
            // sl local_address rem_address st tx:rx tr:when retrnsmt uid timeout inode
            var cols = std.mem.tokenizeScalar(u8, line, ' ');
            _ = cols.next() orelse continue;
            const local = cols.next() orelse continue;
            _ = cols.next() orelse continue;
            const state = cols.next() orelse continue;
            for (0..5) |_| _ = cols.next();
            const inode_s = cols.next() orelse continue;
            if (!std.mem.eql(u8, state, "0A")) continue; // TCP_LISTEN
            const inode = std.fmt.parseUnsigned(u64, inode_s, 10) catch continue;
            if (!inodes.contains(inode)) continue;
            const colon = std.mem.lastIndexOfScalar(u8, local, ':') orelse continue;
            const port = std.fmt.parseUnsigned(u16, local[colon + 1 ..], 16) catch continue;
            try ports.append(allocator, port);
        }
    }
    return ports;
}

/// Wait until `pid` listens on TCP `port`.
fn waitListening(allocator: std.mem.Allocator, pid: std.posix.pid_t, port: u16, ms: u64) !bool {
    const deadline = monoMs() + ms;
    while (true) {
        var ports = try listeningTcpPorts(allocator, pid);
        defer ports.deinit(allocator);
        if (std.mem.indexOfScalar(u16, ports.items, port) != null) return true;
        if (monoMs() >= deadline) return false;
        sleepMs(100);
    }
}

/// A blocking TCP connection to 127.0.0.1:`port`.
fn connectTcp(port: u16) !std.c.fd_t {
    const fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = std.c.close(fd);
    const sa = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = .{0} ** 8,
    };
    if (std.posix.errno(std.c.connect(fd, @ptrCast(&sa), @sizeOf(std.posix.sockaddr.in))) != .SUCCESS)
        return error.ConnectFailed;
    return fd;
}

fn writeAll(fd: std.c.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (rc <= 0) return error.WriteFailed;
        off += @intCast(rc);
    }
}

/// Send an LSP `initialize` request carrying `token` as
/// `initializationOptions.geode.authToken`.
fn sendInitialize(allocator: std.mem.Allocator, fd: std.c.fd_t, id: u32, token: []const u8) !void {
    const body = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"initialize","params":{{"processId":null,"rootUri":null,"capabilities":{{}},"initializationOptions":{{"geode":{{"authToken":"{s}"}}}}}}}}
    , .{ id, token });
    defer allocator.free(body);
    const header = try std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n", .{body.len});
    defer allocator.free(header);
    try writeAll(fd, header);
    try writeAll(fd, body);
}

const ReadResult = enum { found, eof, timeout };

/// Read from `fd` into `out` until it contains `needle`, the peer closes the
/// connection, or `ms` pass.
fn readUntil(allocator: std.mem.Allocator, fd: std.c.fd_t, out: *std.ArrayList(u8), needle: []const u8, ms: u64) !ReadResult {
    const deadline = monoMs() + ms;
    while (true) {
        if (std.mem.indexOf(u8, out.items, needle) != null) return .found;
        const now = monoMs();
        if (now >= deadline) return .timeout;
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = try std.posix.poll(&pfd, @intCast(@min(deadline - now, 1000)));
        if (ready == 0) continue;
        var buf: [4096]u8 = undefined;
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) return .eof; // ECONNRESET: closed by the peer.
        if (n == 0) return .eof;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
}

/// One LSP session: connect, send `initialize` with a token no provider
/// issued, and expect the -32002 "invalid auth token" answer within `ms`.
/// Returns the still-open connection.
fn initializeRejected(allocator: std.mem.Allocator, srv: *const LoggedServer, lsp_port: u16, id: u32, ms: u64) !std.c.fd_t {
    const fd = try connectTcp(lsp_port);
    errdefer _ = std.c.close(fd);
    try sendInitialize(allocator, fd, id, "sonny6374-not-an-issued-token");
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(allocator);
    switch (try readUntil(allocator, fd, &got, "invalid auth token", ms)) {
        .found => {},
        .eof, .timeout => |r| {
            std.debug.print("SONNY-6374: session {d}: no -32002 \"invalid auth token\" answer to initialize ({s} after {d} ms); received {d} bytes: {s}\n", .{ id, @tagName(r), ms, got.items.len, got.items });
            srv.printLog(allocator);
            return error.TestUnexpectedResult;
        },
    }
    try testing.expect(std.mem.indexOf(u8, got.items, "-32002") != null);
    return fd;
}

test "SONNY-6374 (a) every embedded LSP session gets an answer to initialize from the live AuthProvider" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    const lsp_port = try test_ports.freeTcpPort();
    var srv = try LoggedServer.start(allocator, lsp_port);
    defer srv.stop(allocator);
    try srv.waitForLog(allocator, "[startup] server ready", 120_000);
    if (!try waitListening(allocator, srv.handle.child.id.?, lsp_port, 30_000)) {
        std.debug.print("SONNY-6374: the server does not listen on LSP port {d}\n", .{lsp_port});
        srv.printLog(allocator);
        return error.TestUnexpectedResult;
    }

    const first = try initializeRejected(allocator, &srv, lsp_port, 1, 15_000);
    _ = std.c.close(first);
    const second = try initializeRejected(allocator, &srv, lsp_port, 2, 15_000);
    _ = std.c.close(second);
}

/// Wait for `pid` to exit; its exit status, or null after `ms`.
fn waitExit(pid: std.posix.pid_t, ms: u64) ?u32 {
    const deadline = monoMs() + ms;
    while (monoMs() < deadline) {
        var status: u32 = 0;
        const rc = std.os.linux.wait4(pid, &status, std.os.linux.W.NOHANG, null);
        if (rc == pid) return status;
        sleepMs(50);
    }
    return null;
}

test "SONNY-6374 (b) SIGTERM with an LSP session open closes the session, stops the listener and frees the provider" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    const lsp_port = try test_ports.freeTcpPort();
    var srv = try LoggedServer.start(allocator, lsp_port);
    defer srv.stop(allocator);
    try srv.waitForLog(allocator, "[startup] server ready", 120_000);
    if (!try waitListening(allocator, srv.handle.child.id.?, lsp_port, 30_000)) {
        std.debug.print("SONNY-6374: the server does not listen on LSP port {d}\n", .{lsp_port});
        srv.printLog(allocator);
        return error.TestUnexpectedResult;
    }

    const fd = try initializeRejected(allocator, &srv, lsp_port, 1, 15_000);
    defer _ = std.c.close(fd);

    const pid = srv.handle.child.id.?;
    try std.posix.kill(pid, .TERM);

    // The server closes the open session itself during shutdown.
    var rest: std.ArrayList(u8) = .empty;
    defer rest.deinit(allocator);
    const r = try readUntil(allocator, fd, &rest, "\x00never\x00", 60_000);
    if (r != .eof) {
        std.debug.print("SONNY-6374: the open LSP session was not closed within 60 s of SIGTERM\n", .{});
        srv.printLog(allocator);
        return error.TestUnexpectedResult;
    }

    const status = waitExit(pid, 120_000) orelse {
        std.debug.print("SONNY-6374: the server did not exit within 120 s of SIGTERM\n", .{});
        srv.printLog(allocator);
        return error.TestUnexpectedResult;
    };
    srv.handle.child.id = null; // reaped
    const exited_zero = std.os.linux.W.IFEXITED(status) and std.os.linux.W.EXITSTATUS(status) == 0;

    const text = try srv.log(allocator);
    defer allocator.free(text);
    const stopped = std.mem.indexOf(u8, text, "[shutdown] LSP listener stopped") != null;
    const leaked = std.mem.indexOf(u8, text, "leaked") != null;
    if (!exited_zero or !stopped or leaked) {
        std.debug.print("SONNY-6374: exit status 0x{x} (want exit 0), \"LSP listener stopped\" logged: {}, leak report: {}\n", .{ status, stopped, leaked });
        srv.printLog(allocator);
        return error.TestUnexpectedResult;
    }
}
