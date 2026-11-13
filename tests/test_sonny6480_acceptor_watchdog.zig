// SONNY-6480: the accept-path wedge watchdog watches the listener it serves.
//
//   1. The watchdog's port was parsed from the `--listen` text, so `--listen
//      host:0` (an ephemeral port) left it off. It now takes the transport's
//      bound address.
//   2. It read only /proc/net/udp, so an IPv6 listener was never watched, and
//      it matched a row by port alone, so another socket on the same port (a
//      different address, or a second process's socket on the same address)
//      could be read instead. It now reads /proc/net/udp6 for an IPv6
//      listener and matches the bound address and port, and among several
//      sockets on that address the one this process owns.
//   3. Since SONNY-2719 a wedge needs zero datagrams drained between samples,
//      so the backlog threshold no longer has to sit far above any burst a
//      draining acceptor could leave queued. The default drops from 8 MiB to
//      one byte (any queued datagram), which closes the idle-wedge gap: a
//      wedged acceptor holding a few connection attempts is detected within
//      the deadline (30 s of samples), while a busy one that drains is never
//      restarted whatever its backlog.
//
// Real sockets and a real `geode serve`; nothing is simulated. The kernel's
// /proc tables are read as the watchdog reads them.
//
// CANARY: REQ=REQ-SONNY-6480-WATCHDOG-LISTENER; FEATURE="QUIC High-Concurrency Connection Admission"; ASPECT=WatchesBoundListener; STATUS=TESTED; TEST=tests/test_sonny6480_acceptor_watchdog.zig; OWNER=transport; UPDATED=2026-11-13

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const aw = @import("acceptor_watchdog");
const geode_test_bin = @import("geode_test_bin");

const linux = std.os.linux;

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

fn udpSocket(family: u32) !i32 {
    const rc = linux.socket(family, linux.SOCK.DGRAM, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    return @intCast(rc);
}

fn bindV4(fd: i32, ip: u32, port: u16) !linux.sockaddr.in {
    var sa: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, ip) };
    if (linux.errno(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.BindFailed;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.getsockname(fd, @ptrCast(&sa), &len)) != .SUCCESS) return error.GetSockNameFailed;
    return sa;
}

fn sendDatagrams(fd: i32, dest: *const anyopaque, len: linux.socklen_t, n: usize) !void {
    var payload: [200]u8 = undefined;
    @memset(&payload, 0x5a);
    for (0..n) |_| {
        if (linux.errno(linux.sendto(fd, &payload, payload.len, 0, @ptrCast(@alignCast(dest)), len)) != .SUCCESS) return error.SendFailed;
    }
}

test "SONNY-6480: an IPv6 listener's backlog is read from /proc/net/udp6" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const rx_fd = udpSocket(linux.AF.INET6) catch return error.SkipZigTest;
    defer _ = linux.close(rx_fd);
    var sa: linux.sockaddr.in6 = .{ .port = 0, .flowinfo = 0, .addr = [_]u8{0} ** 15 ++ [_]u8{1}, .scope_id = 0 };
    if (linux.errno(linux.bind(rx_fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in6))) != .SUCCESS) return error.SkipZigTest; // no IPv6 loopback
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in6);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.getsockname(rx_fd, @ptrCast(&sa), &len)));
    const listener = aw.ListenerAddr.fromSockaddrIn6(sa);

    // Nothing queued yet: the row is found, and empty.
    try testing.expectEqual(@as(?u64, 0), aw.readListenerRxQueue(listener));

    const tx_fd = try udpSocket(linux.AF.INET6);
    defer _ = linux.close(tx_fd);
    try sendDatagrams(tx_fd, &sa, @sizeOf(linux.sockaddr.in6), 5);
    sleepMs(50);
    const rx = aw.readListenerRxQueue(listener) orelse return error.ListenerNotFound;
    try testing.expect(rx > 0);
}

test "SONNY-6480: two sockets on one port are told apart by address" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a_fd = try udpSocket(linux.AF.INET);
    defer _ = linux.close(a_fd);
    const b_fd = try udpSocket(linux.AF.INET);
    defer _ = linux.close(b_fd);
    // 127.0.0.1:P and 127.0.0.2:P, the same port.
    const a = try bindV4(a_fd, 0x7f000001, 0);
    const port = std.mem.bigToNative(u16, a.port);
    const b = bindV4(b_fd, 0x7f000002, port) catch return error.SkipZigTest;

    const tx_fd = try udpSocket(linux.AF.INET);
    defer _ = linux.close(tx_fd);
    try sendDatagrams(tx_fd, &b, @sizeOf(linux.sockaddr.in), 6);
    sleepMs(50);

    // Only B's queue holds the datagrams; reading by port alone could not
    // say which row is A's.
    try testing.expectEqual(@as(?u64, 0), aw.readListenerRxQueue(aw.ListenerAddr.fromSockaddrIn(a)));
    const rx_b = aw.readListenerRxQueue(aw.ListenerAddr.fromSockaddrIn(b)) orelse return error.ListenerNotFound;
    try testing.expect(rx_b > 0);
}

test "SONNY-6480: among sockets on one address and port, the one this process owns is read" {
    const text =
        "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops\n" ++
        "  10: 0100007F:0C45 00000000:0000 07 00000000:00100000 00:00000000 00000000  1000        0 111 2 0000000000000000 0\n" ++
        "  11: 0100007F:0C45 00000000:0000 07 00000000:00000300 00:00000000 00000000  1000        0 222 2 0000000000000000 0\n" ++
        "  12: 0200007F:0C45 00000000:0000 07 00000000:00000700 00:00000000 00000000  1000        0 333 2 0000000000000000 0\n";
    const addr: aw.ListenerAddr = .{ .family = .ipv4, .ip = [_]u8{ 127, 0, 0, 1 } ++ [_]u8{0} ** 12, .port = 0x0C45 };
    // Owned socket 222: its row, not the first one on the port.
    try testing.expectEqual(@as(?u64, 0x300), aw.parseListenerRxQueue(text, addr, &.{ 999, 222 }));
    // One candidate row: taken without the ownership check.
    const other: aw.ListenerAddr = .{ .family = .ipv4, .ip = [_]u8{ 127, 0, 0, 2 } ++ [_]u8{0} ** 12, .port = 0x0C45 };
    try testing.expectEqual(@as(?u64, 0x700), aw.parseListenerRxQueue(text, other, &.{}));
    // Two candidates and neither owned: not this process's listener.
    try testing.expectEqual(@as(?u64, null), aw.parseListenerRxQueue(text, addr, &.{999}));
    // IPv6 rows: the address is four host-order 32-bit words.
    const text6 =
        "  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops\n" ++
        "  5: 00000000000000000000000001000000:0C45 00000000000000000000000000000000:0000 07 00000000:00000A00 00:00000000 00000000  1000        0 444 2 0000000000000000 0\n";
    const v6: aw.ListenerAddr = .{ .family = .ipv6, .ip = [_]u8{0} ** 15 ++ [_]u8{1}, .port = 0x0C45 };
    try testing.expectEqual(@as(?u64, 0xA00), aw.parseListenerRxQueue(text6, v6, &.{}));
}

test "SONNY-6480: with the default threshold a wedge holding one datagram is restarted within the deadline, a draining acceptor never" {
    const cfg = aw.parseConfig(null, null, null);
    // One queued 1200-byte QUIC Initial: the kernel accounts ~2.3 KiB.
    const one_initial: u64 = 2304;
    // Wedged: samples every 5 s, nothing drained. The first backlogged
    // sample starts the streak; the deadline after it, a restart.
    {
        var t = aw.WedgeTracker{};
        var now: i64 = 0;
        var restarted_at: ?i64 = null;
        while (now <= 120_000) : (now += 5_000) {
            if (t.update(one_initial, 41, now, cfg) == .restart) {
                restarted_at = now;
                break;
            }
        }
        const at = restarted_at orelse return error.WedgeNotDetected;
        try testing.expect(at <= aw.default_deadline_ms + 5_000);
    }
    // Busy but draining: a large backlog at every sample, datagrams drained
    // between samples. Ten minutes, no restart.
    {
        var t = aw.WedgeTracker{};
        var drained: u64 = 0;
        var now: i64 = 0;
        while (now <= 600_000) : (now += 5_000) {
            try testing.expectEqual(aw.Action.ok, t.update(12 * 1024 * 1024, drained, now, cfg));
            drained += 1;
        }
    }
    // Idle: nothing queued, nothing drained. Never a restart.
    {
        var t = aw.WedgeTracker{};
        var now: i64 = 0;
        while (now <= 600_000) : (now += 5_000) {
            try testing.expectEqual(aw.Action.ok, t.update(0, 7, now, cfg));
        }
    }
}

// ---------------------------------------------------------------------------
// A real `geode serve` on an ephemeral port, IPv4 and IPv6.
// ---------------------------------------------------------------------------

const Server = struct {
    threaded: std.Io.Threaded,
    child: std.process.Child,
    env: std.process.Environ.Map,
    data_dir: []const u8,

    fn start(allocator: std.mem.Allocator, listen: []const u8, data_dir: []const u8) !Server {
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        errdefer threaded.deinit();
        const io = threaded.io();
        var env = try std.Io.Threaded.global_single_threaded.environ.process_environ.createMap(allocator);
        errdefer env.deinit();
        try env.put("GEODE_ADMIN_USERNAME", "geode");
        try env.put("GEODE_ADMIN_PASSWORD", "Geode Test Admin Passphrase");
        try std.Io.Dir.cwd().createDirPath(io, data_dir);
        const child = try std.process.spawn(io, .{
            .argv = &.{ geode_test_bin.geode_exe, "serve", "--listen", listen, "--data-dir", data_dir },
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .pipe,
        });
        return .{ .threaded = threaded, .child = child, .env = env, .data_dir = data_dir };
    }

    /// The first stderr line containing `needle`, within `timeout_ms`.
    fn waitForLine(self: *Server, buf: []u8, needle: []const u8, timeout_ms: u64) ![]const u8 {
        const fd = self.child.stderr.?.handle;
        var used: usize = 0;
        const deadline = std.Io.Clock.awake.now(self.threaded.io()).toMilliseconds() + @as(i64, @intCast(timeout_ms));
        while (std.Io.Clock.awake.now(self.threaded.io()).toMilliseconds() < deadline) {
            var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
            const ready = linux.poll(&pfd, 1, 200);
            if (linux.errno(ready) != .SUCCESS or ready == 0) continue;
            if (used == buf.len) used = 0; // keep only recent output
            const n = linux.read(fd, buf[used..].ptr, buf.len - used);
            if (linux.errno(n) != .SUCCESS or n == 0) return error.ServerExited;
            used += n;
            var lines = std.mem.splitScalar(u8, buf[0..used], '\n');
            while (lines.next()) |line| {
                if (std.mem.indexOf(u8, line, needle) != null and lines.peek() != null) return line;
            }
        }
        return error.LineNotSeen;
    }

    fn stop(self: *Server) void {
        const io = self.threaded.io();
        self.child.kill(io);
        std.Io.Dir.cwd().deleteTree(io, self.data_dir) catch {};
        self.env.deinit();
        self.threaded.deinit();
    }
};

fn checkServerWatchesBoundListener(listen: []const u8, family_tag: []const u8) !void {
    const allocator = testing.allocator;
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny6480-{d}-{s}", .{ linux.getpid(), std.mem.trim(u8, family_tag, " ") });
    var server = try Server.start(allocator, listen, data_dir);
    defer server.stop();
    var buf: [64 * 1024]u8 = undefined;
    // The watchdog announces the listener it watches.
    const line = try server.waitForLine(&buf, "acceptor watchdog: watching", 60_000);
    try testing.expect(std.mem.indexOf(u8, line, family_tag) != null);
    // `... watching <udp|udp6> <address> port <n>`: the bound port, not 0.
    const at = std.mem.lastIndexOf(u8, line, "port ") orelse return error.NoPort;
    const port_text = std.mem.trim(u8, line[at + 5 ..], " \r\n");
    const port = try std.fmt.parseInt(u16, port_text, 10);
    try testing.expect(port != 0);
}

test "SONNY-6480: geode serve --listen 127.0.0.1:0 watches its bound UDP port" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    try checkServerWatchesBoundListener("127.0.0.1:0", "udp ");
}

test "SONNY-6480: geode serve --listen [::1]:0 watches its IPv6 listener" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    // Skip on a host without IPv6 loopback.
    const fd = udpSocket(linux.AF.INET6) catch return error.SkipZigTest;
    defer _ = linux.close(fd);
    var sa: linux.sockaddr.in6 = .{ .port = 0, .flowinfo = 0, .addr = [_]u8{0} ** 15 ++ [_]u8{1}, .scope_id = 0 };
    if (linux.errno(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in6))) != .SUCCESS) return error.SkipZigTest;
    try checkServerWatchesBoundListener("[::1]:0", "udp6 ");
}
