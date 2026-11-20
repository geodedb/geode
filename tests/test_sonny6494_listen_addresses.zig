// SONNY-6494 item 5: listen addresses.
//
// 1. QuicTransport bound "{address}:{port}", so an IPv6 address written
//    without brackets (GEODE_CLUSTER_LISTEN_ADDRESS=::1, which the cluster
//    listener passes to QuicTransport as written) became "::1:4242", which
//    the QUIC library cannot parse: the cluster listener could not start on
//    IPv6. Real listens on ::1, bracketed and bare.
// 2. A port-only --listen-grpc bound 0.0.0.0 when the QUIC listener (the
//    --listen address a port alone binds, SONNY-1336) was IPv6 or a host
//    name, so gRPC listened on every IPv4 interface while QUIC listened on
//    loopback. It is now refused (exit 2) like an IPv6 --listen-grpc.
// 3. The acceptor watchdog watches the bound listener for `--listen <port>`
//    and `--listen <host>` (SONNY-6480 rewired it to boundAddress()).
//    127.0.0.103 is an address no other test step uses (SONNY-6460), so the
//    default port 3141 it binds there cannot collide.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const quic = @import("transport/quic");
const cli_args = @import("cli_args");
const geode_test_bin = @import("geode_test_bin");
const test_ports = @import("test_ports.zig");

const testing = std.testing;

fn hasIpv6Loopback() bool {
    const fd_rc = linux.socket(linux.AF.INET6, linux.SOCK.DGRAM, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var sa: linux.sockaddr.in6 = .{ .port = 0, .flowinfo = 0, .addr = [_]u8{0} ** 15 ++ [_]u8{1}, .scope_id = 0 };
    return linux.errno(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in6))) == .SUCCESS;
}

fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(gpa, io, .{ .argv = argv });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.OpensslFailed;
}

fn tmpDirPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var n = cwd_len;
    while (n > 0 and cwd_buf[n - 1] == 0) : (n -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..n], &tmp.sub_path });
}

/// Listens a QuicTransport on `address` (as the cluster listener passes it)
/// at a free port and checks the socket is bound to ::1 at that port.
fn listenIpv6(address: []const u8, cert: []const u8, key: []const u8) !void {
    const a = testing.allocator;
    const port = try test_ports.freeUdpPort();
    var t = try quic.QuicTransport.init(a, .{
        .address = address,
        .port = port,
        .cert_path = cert,
        .key_path = key,
        .cert_auto_generate = .never,
    });
    defer t.deinit();
    try t.listen();
    const st = t.boundAddress() orelse return error.NotBound;
    try testing.expectEqual(@as(u16, std.posix.AF.INET6), st.family);
    const sin6: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(&st));
    try testing.expectEqual(port, std.mem.bigToNative(u16, sin6.port));
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 15 ++ [_]u8{1}), &sin6.addr);
}

test "SONNY-6494: the QUIC bind address brackets an IPv6 host however it was written" {
    const a = testing.allocator;
    const Case = struct { address: []const u8, port: u16, want: []const u8 };
    for ([_]Case{
        .{ .address = "::1", .port = 4242, .want = "[::1]:4242" },
        .{ .address = "[::1]", .port = 4242, .want = "[::1]:4242" },
        .{ .address = "::", .port = 1, .want = "[::]:1" },
        .{ .address = "fe80::1%lo", .port = 3141, .want = "[fe80::1%lo]:3141" },
        .{ .address = "0.0.0.0", .port = 3141, .want = "0.0.0.0:3141" },
        .{ .address = "127.0.0.2", .port = 0, .want = "127.0.0.2:0" },
        .{ .address = "localhost", .port = 3141, .want = "127.0.0.1:3141" },
    }) |c| {
        const got = try quic.QuicTransport.formatBindAddress(a, c.address, c.port);
        defer a.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

const CertFixture = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,
    key: []u8,
    cert: []u8,

    /// A self-signed P-256 certificate made with openssl (skips without it).
    fn make() !CertFixture {
        const a = testing.allocator;
        const spawn_gpa = std.heap.smp_allocator;
        var threaded = std.Io.Threaded.init(spawn_gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        run(spawn_gpa, io, &.{ "openssl", "version" }) catch return error.SkipZigTest;
        var fx: CertFixture = undefined;
        fx.tmp = std.testing.tmpDir(.{});
        errdefer fx.tmp.cleanup();
        fx.dir = try tmpDirPath(a, &fx.tmp);
        errdefer a.free(fx.dir);
        fx.key = try std.fmt.allocPrint(a, "{s}/k.pem", .{fx.dir});
        errdefer a.free(fx.key);
        fx.cert = try std.fmt.allocPrint(a, "{s}/c.pem", .{fx.dir});
        errdefer a.free(fx.cert);
        try run(spawn_gpa, io, &.{ "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", fx.key, "-out", fx.cert, "-days", "1", "-subj", "/CN=sonny6494" });
        return fx;
    }

    fn deinit(self: *CertFixture) void {
        const a = testing.allocator;
        a.free(self.cert);
        a.free(self.key);
        a.free(self.dir);
        self.tmp.cleanup();
    }
};

test "SONNY-6494: the QUIC listener binds an IPv6 address written bare (as GEODE_CLUSTER_LISTEN_ADDRESS may be) or bracketed" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    if (!hasIpv6Loopback()) return error.SkipZigTest;
    var fx = try CertFixture.make();
    defer fx.deinit();
    try listenIpv6("::1", fx.cert, fx.key);
    try listenIpv6("[::1]", fx.cert, fx.key);
}

test "SONNY-6494: a QUIC listen that cannot bind returns its error and leaves the transport safe to deinit" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var fx = try CertFixture.make();
    defer fx.deinit();
    // 192.0.2.1 (TEST-NET-1) is on no local interface: the bind fails.
    var t = try quic.QuicTransport.init(testing.allocator, .{
        .address = "192.0.2.1",
        .port = try test_ports.freeUdpPort(),
        .cert_path = fx.cert,
        .key_path = fx.key,
        .cert_auto_generate = .never,
    });
    defer t.deinit();
    if (t.listen()) |_| return error.UnexpectedBind else |_| {}
    try testing.expect(t.boundAddress() == null);
}

test "SONNY-6494: a port-only --listen-grpc is refused when the --listen address is not IPv4, never widened to 0.0.0.0" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    for ([_][]const u8{ "[::1]:3141", "[::]:3141", "geode.example:3141", "geode.example" }) |quic_listen| {
        try testing.expectError(error.GrpcPortOnlyListenNotIpv4, cli_args.resolveGrpcBind("50051", quic_listen));
        try testing.expectError(error.GrpcPortOnlyListenNotIpv4, cli_args.resolveGrpcBind(":50051", quic_listen));
    }
    // An IPv4 or localhost --listen is bound by gRPC too.
    try testing.expectEqualStrings("127.0.0.2", (try cli_args.resolveGrpcBind("50051", "127.0.0.2:3141")).address);
    try testing.expectEqualStrings("127.0.0.1", (try cli_args.resolveGrpcBind("50051", "localhost:3141")).address);
    // A port-only --listen binds 0.0.0.0, and so does gRPC; with no --listen,
    // gRPC keeps QUIC's port-only default.
    try testing.expectEqualStrings("0.0.0.0", (try cli_args.resolveGrpcBind("50051", "3141")).address);
    try testing.expectEqualStrings("0.0.0.0", (try cli_args.resolveGrpcBind("50051", null)).address);
}

const Server = struct {
    threaded: std.Io.Threaded,
    child: std.process.Child,
    env: std.process.Environ.Map,
    data_dir: []const u8,

    fn start(allocator: std.mem.Allocator, argv_tail: []const []const u8, data_dir: []const u8) !Server {
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        errdefer threaded.deinit();
        const io = threaded.io();
        var env = try std.Io.Threaded.global_single_threaded.environ.process_environ.createMap(allocator);
        errdefer env.deinit();
        try env.put("GEODE_ADMIN_USERNAME", "geode");
        try env.put("GEODE_ADMIN_PASSWORD", "Geode Test Admin Passphrase");
        try std.Io.Dir.cwd().createDirPath(io, data_dir);
        var argv: [16][]const u8 = undefined;
        argv[0] = geode_test_bin.geode_exe;
        argv[1] = "serve";
        argv[2] = "--data-dir";
        argv[3] = data_dir;
        @memcpy(argv[4..][0..argv_tail.len], argv_tail);
        const child = try std.process.spawn(io, .{
            .argv = argv[0 .. 4 + argv_tail.len],
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .pipe,
        });
        return .{ .threaded = threaded, .child = child, .env = env, .data_dir = data_dir };
    }

    /// Reads stderr until a line contains `needle` (returned) or the process
    /// exits (error.ServerExited; `out` then holds everything it wrote).
    fn waitForLine(self: *Server, buf: []u8, needle: []const u8, timeout_ms: u64, out: *[]const u8) ![]const u8 {
        const fd = self.child.stderr.?.handle;
        var used: usize = 0;
        const deadline = std.Io.Clock.awake.now(self.threaded.io()).toMilliseconds() + @as(i64, @intCast(timeout_ms));
        while (std.Io.Clock.awake.now(self.threaded.io()).toMilliseconds() < deadline) {
            var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
            const ready = linux.poll(&pfd, 1, 200);
            if (linux.errno(ready) != .SUCCESS or ready == 0) continue;
            if (used == buf.len) used = 0;
            const n = linux.read(fd, buf[used..].ptr, buf.len - used);
            out.* = buf[0..used];
            if (linux.errno(n) != .SUCCESS or n == 0) return error.ServerExited;
            used += n;
            out.* = buf[0..used];
            var lines = std.mem.splitScalar(u8, buf[0..used], '\n');
            while (lines.next()) |line| {
                if (std.mem.indexOf(u8, line, needle) != null and lines.peek() != null) return line;
            }
        }
        return error.LineNotSeen;
    }

    fn wait(self: *Server) !std.process.Child.Term {
        return self.child.wait(self.threaded.io());
    }

    fn stop(self: *Server) void {
        const io = self.threaded.io();
        self.child.kill(io);
        self.cleanup();
    }

    fn cleanup(self: *Server) void {
        const io = self.threaded.io();
        std.Io.Dir.cwd().deleteTree(io, self.data_dir) catch {};
        self.env.deinit();
        self.threaded.deinit();
    }
};

fn dataDir(buf: []u8, tag: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "/tmp/geode-sonny6494-{d}-{s}", .{ linux.getpid(), tag });
}

fn expectWatchdogWatches(argv_tail: []const []const u8, tag: []const u8, expect_table: []const u8, expect_addr: []const u8, expect_port: ?u16) !void {
    var dir_buf: [96]u8 = undefined;
    var server = try Server.start(testing.allocator, argv_tail, try dataDir(&dir_buf, tag));
    defer server.stop();
    var buf: [64 * 1024]u8 = undefined;
    var out: []const u8 = "";
    const line = server.waitForLine(&buf, "acceptor watchdog: watching", 60_000, &out) catch |err| {
        std.debug.print("geode serve {s}: {s}\n{s}\n", .{ argv_tail[1], @errorName(err), out });
        return err;
    };
    // `... watching <udp|udp6> <address> port <n>`
    const needle = try std.fmt.allocPrint(testing.allocator, "watching {s} {s} port ", .{ expect_table, expect_addr });
    defer testing.allocator.free(needle);
    if (std.mem.indexOf(u8, line, needle) == null) {
        std.debug.print("expected \"{s}\" in: {s}\n", .{ needle, line });
        return error.WrongListener;
    }
    const at = std.mem.lastIndexOf(u8, line, "port ") orelse return error.NoPort;
    const port = try std.fmt.parseInt(u16, std.mem.trim(u8, line[at + 5 ..], " \r\n"), 10);
    if (expect_port) |p| try testing.expectEqual(p, port) else try testing.expect(port != 0);
}

test "SONNY-6494: geode serve --listen <port> watches 0.0.0.0 at that port" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const port = try test_ports.freeUdpPort();
    var port_buf: [8]u8 = undefined;
    const port_text = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
    try expectWatchdogWatches(&.{ "--listen", port_text }, "port", "udp", "0.0.0.0", port);
}

test "SONNY-6494: geode serve --listen <host> watches that host at the default port" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    try expectWatchdogWatches(&.{ "--listen", "127.0.0.103" }, "host", "udp", "127.0.0.103", 3141);
}

test "SONNY-6494: geode serve refuses a port-only --listen-grpc when --listen is IPv6" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const grpc_port = try test_ports.freeTcpPort();
    var port_buf: [8]u8 = undefined;
    const grpc_text = try std.fmt.bufPrint(&port_buf, "{d}", .{grpc_port});
    var dir_buf: [96]u8 = undefined;
    var server = try Server.start(testing.allocator, &.{ "--listen", "[::1]:0", "--listen-grpc", grpc_text }, try dataDir(&dir_buf, "grpc"));
    var buf: [64 * 1024]u8 = undefined;
    var out: []const u8 = "";
    const seen = server.waitForLine(&buf, "--listen-grpc", 60_000, &out);
    if (seen) |_| {} else |err| switch (err) {
        error.ServerExited => {},
        else => {
            server.stop();
            return err;
        },
    }
    if (std.mem.indexOf(u8, out, "listening") != null and std.mem.indexOf(u8, out, "\"grpc\"") != null) {
        server.stop();
        std.debug.print("gRPC listened:\n{s}\n", .{out});
        return error.GrpcWidened;
    }
    const term = server.wait() catch |err| {
        server.cleanup();
        return err;
    };
    server.cleanup();
    if (std.mem.indexOf(u8, out, "a port alone binds the --listen address") == null) {
        std.debug.print("stderr:\n{s}\n", .{out});
        return error.NoClearMessage;
    }
    try testing.expect(term == .exited and term.exited == 2);
}
