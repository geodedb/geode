// SONNY-1336: `geode serve --listen-grpc <addr:port>` must listen on <addr>.
//
// src/server/main.zig parsed the host out of --listen-grpc and used it only in
// a log line: GeodeGrpcServer.init received the port alone and called
// grpc-zig's `GrpcServer.init`, which binds GRPC_ZIG_BIND_ADDR or, by
// default, 127.0.0.1. `--listen-grpc 0.0.0.0:50051` in a container therefore
// listened on loopback only and a published port reached nothing. A port that
// did not parse silently became 3142 (the embedded LSP port), and an address
// grpc-zig cannot bind (IPv6, a host name) was silently replaced by loopback.
//
// The pinned grpc-zig (fe88ba8d, 0.1.15) has `GrpcServer.initWithBind`, which
// binds a given IPv4 address. Each case below starts the real built
// `geode serve` and reads the kernel's socket table (/proc/net/tcp) for the
// LISTEN socket, then speaks the real gRPC HELLO to the address it asked for:
//   * an explicit IPv4 address (127.0.0.2, 0.0.0.0) is the address bound;
//   * a port alone binds the QUIC listener's address, or 0.0.0.0 (the QUIC
//     port-only default) when there is no QUIC listener;
//   * the startup banner names the address and port bound;
//   * an address grpc-zig cannot bind (IPv6, a host name) or a bad port is
//     refused at startup (exit 2) naming --listen-grpc, and nothing listens.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const proto_util = @import("proto_test_util.zig");
const test_ports = @import("test_ports.zig");
const test_scratch = @import("test_scratch.zig");

const linux = std.os.linux;
const posix = std.posix;

const startup_deadline_ms: i64 = 90_000;
const refusal_deadline_ms: i64 = 30_000;

fn nowMillis() i64 {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
}

fn sleepMs(ms: u64) void {
    var req = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    var rem: linux.timespec = undefined;
    _ = linux.nanosleep(&req, &rem);
}

fn setNonBlocking(file: std.Io.File) void {
    const flags = linux.fcntl(file.handle, posix.F.GETFL, 0);
    if (@as(isize, @bitCast(flags)) < 0) return;
    _ = linux.fcntl(file.handle, posix.F.SETFL, flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
}

/// A spawned `geode serve` with piped output and a bounded transcript.
const Server = struct {
    threaded: *std.Io.Threaded,
    env: *std.process.Environ.Map,
    child: std.process.Child,
    transcript: std.ArrayList(u8) = .empty,
    exit_code: ?u8 = null,
    reaped: bool = false,
    data_dir: test_scratch.ScratchDir,

    fn start(extra_args: []const []const u8) !Server {
        var data_dir = try test_scratch.ScratchDir.create("sonny1336-grpc-bind");
        errdefer data_dir.remove();
        const threaded = try testing.allocator.create(std.Io.Threaded);
        errdefer testing.allocator.destroy(threaded);
        threaded.* = std.Io.Threaded.init(testing.allocator, .{});
        errdefer threaded.deinit();

        const env = try testing.allocator.create(std.process.Environ.Map);
        errdefer testing.allocator.destroy(env);
        env.* = try std.Io.Threaded.global_single_threaded.environ.process_environ.createMap(testing.allocator);
        errdefer env.deinit();
        try env.put("GEODE_ADMIN_USERNAME", proto_util.defaultUsername());
        try env.put("GEODE_ADMIN_PASSWORD", proto_util.defaultPassword());
        try env.put("GEODE_DEFAULT_PASSWORD", proto_util.defaultPassword());
        try env.put("GEODE_GRPC_ALLOW_PLAINTEXT_FALLBACK", "1");
        try env.put("GEODE_LSP_PORT", "0");
        // The library-level workaround must not decide the bind any more.
        _ = env.swapRemove("GRPC_ZIG_BIND_ADDR");

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(testing.allocator);
        try argv.appendSlice(testing.allocator, &.{ geode_test_bin.geode_exe, "serve", "--data-dir", data_dir.path() });
        try argv.appendSlice(testing.allocator, extra_args);

        const child = try std.process.spawn(threaded.io(), .{
            .argv = argv.items,
            .environ_map = env,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        setNonBlocking(child.stdout.?);
        setNonBlocking(child.stderr.?);
        return .{ .threaded = threaded, .env = env, .child = child, .data_dir = data_dir };
    }

    fn drain(self: *Server) void {
        var buf: [8192]u8 = undefined;
        inline for (.{ self.child.stdout, self.child.stderr }) |maybe_f| {
            if (maybe_f) |f| {
                while (self.transcript.items.len < 4 << 20) {
                    const n = f.readStreaming(std.Io.Threaded.global_single_threaded.io(), &.{&buf}) catch break;
                    if (n == 0) break;
                    self.transcript.appendSlice(testing.allocator, buf[0..n]) catch break;
                }
            }
        }
    }

    /// True once the child has exited (records its exit code).
    fn pollExit(self: *Server) bool {
        if (self.reaped) return true;
        const pid = self.child.id orelse return true;
        var status: u32 = 0;
        const rc: isize = @bitCast(linux.waitpid(pid, &status, linux.W.NOHANG));
        if (rc == pid or rc < 0) {
            self.reaped = true;
            self.exit_code = if (rc == pid and linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else 255;
            self.drain();
            return true;
        }
        return false;
    }

    fn saw(self: *const Server, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.transcript.items, needle) != null;
    }

    fn dump(self: *const Server, label: []const u8) void {
        const t = self.transcript.items;
        const tail = if (t.len > 3000) t[t.len - 3000 ..] else t;
        std.debug.print("\nSONNY-1336 {s}: exit={any}\n--- server output (tail) ---\n{s}\n--- end ---\n", .{ label, self.exit_code, tail });
    }

    fn deinit(self: *Server) void {
        if (!self.reaped) {
            if (self.child.id) |pid| {
                posix.kill(pid, .KILL) catch {};
                var status: u32 = 0;
                _ = linux.waitpid(pid, &status, 0);
            }
        }
        if (self.child.stdout) |f| f.close(self.threaded.io());
        if (self.child.stderr) |f| f.close(self.threaded.io());
        self.transcript.deinit(testing.allocator);
        self.env.deinit();
        testing.allocator.destroy(self.env);
        self.threaded.deinit();
        testing.allocator.destroy(self.threaded);
        self.data_dir.remove();
    }
};

/// /proc/net/tcp local address for an IPv4 address and port, e.g.
/// 127.0.0.2:50051 -> "0200007F:C383" (address in host byte order on x86).
fn procTcpKey(buf: []u8, ip: [4]u8, port: u16) ![]const u8 {
    const word = std.mem.readInt(u32, &ip, .little);
    return std.fmt.bufPrint(buf, "{X:0>8}:{X:0>4}", .{ word, port });
}

/// Local addresses of every LISTEN (state 0A) TCP socket on `port`.
fn listenersOnPort(port: u16, out: *[8][13]u8) !usize {
    // procfs reports a size of 0, so read it to EOF rather than by its size.
    const fd = std.c.open("/proc/net/tcp", .{});
    if (fd < 0) return error.ProcNetTcpUnreadable;
    defer _ = std.c.close(fd);
    var data_list: std.ArrayList(u8) = .empty;
    defer data_list.deinit(testing.allocator);
    var chunk: [16384]u8 = undefined;
    while (true) {
        const got = std.c.read(fd, &chunk, chunk.len);
        if (got < 0) return error.ProcNetTcpUnreadable;
        if (got == 0) break;
        try data_list.appendSlice(testing.allocator, chunk[0..@intCast(got)]);
    }
    const data = data_list.items;
    var port_buf: [5]u8 = undefined;
    const port_hex = try std.fmt.bufPrint(&port_buf, ":{X:0>4}", .{port});
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse continue; // "sl:"
        const local = fields.next() orelse continue;
        _ = fields.next() orelse continue; // remote
        const state = fields.next() orelse continue;
        if (!std.mem.eql(u8, state, "0A")) continue;
        if (local.len != 13 or !std.mem.endsWith(u8, local, port_hex)) continue;
        if (n < out.len) {
            @memcpy(&out[n], local[0..13]);
            n += 1;
        }
    }
    return n;
}

/// Wait until something listens on TCP `port` (or the server exits).
/// Returns the listening local addresses found.
fn waitForListener(server: *Server, port: u16, out: *[8][13]u8) !usize {
    const t0 = nowMillis();
    while (nowMillis() - t0 < startup_deadline_ms) {
        server.drain();
        const n = try listenersOnPort(port, out);
        if (n > 0) return n;
        if (server.pollExit()) return 0;
        sleepMs(100);
    }
    return 0;
}

fn expectListensOn(extra_args: []const []const u8, grpc_port: u16, want_ip: [4]u8, dial: []const u8, label: []const u8) !void {
    var server = try Server.start(extra_args);
    defer server.deinit();

    var found: [8][13]u8 = undefined;
    const n = try waitForListener(&server, grpc_port, &found);
    var key_buf: [16]u8 = undefined;
    const want = try procTcpKey(&key_buf, want_ip, grpc_port);
    var bound_wanted = false;
    for (found[0..n]) |local| {
        if (std.mem.eql(u8, &local, want)) bound_wanted = true;
    }
    if (!bound_wanted or n != 1) {
        std.debug.print("SONNY-1336 {s}: wanted exactly one LISTEN socket {s}; found {d}:\n", .{ label, want, n });
        for (found[0..n]) |local| std.debug.print("  {s}\n", .{&local});
        server.dump(label);
    }
    try testing.expect(bound_wanted);
    try testing.expectEqual(@as(usize, 1), n);

    // The listener answers geode's gRPC protocol at the address asked for.
    var client = try proto_util.GrpcProtoClient.connect(testing.allocator, dial);
    defer client.deinit();
    var hello = try client.hello(testing.allocator, proto_util.defaultUsername(), proto_util.defaultPassword());
    defer hello.deinit(testing.allocator);
    if (!hello.success) server.dump(label);
    try testing.expect(hello.success);

    // The startup banner names the address and port actually bound.
    var ip_buf: [16]u8 = undefined;
    const ip_text = try std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ want_ip[0], want_ip[1], want_ip[2], want_ip[3] });
    var banner_buf: [160]u8 = undefined;
    const banner = try std.fmt.bufPrint(&banner_buf, "\"transport\":\"grpc\",\"address\":\"{s}\",\"port\":{d}", .{ ip_text, grpc_port });
    server.drain();
    if (!server.saw(banner)) {
        std.debug.print("SONNY-1336 {s}: no startup banner containing {s}\n", .{ label, banner });
        server.dump(label);
    }
    try testing.expect(server.saw(banner));
}

test "SONNY-1336 --listen-grpc 127.0.0.2:<port> listens on 127.0.0.2, not 127.0.0.1" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const port = try test_ports.freeTcpPort();
    var arg_buf: [32]u8 = undefined;
    const arg = try std.fmt.bufPrint(&arg_buf, "127.0.0.2:{d}", .{port});
    try expectListensOn(&.{ "--listen-grpc", arg }, port, .{ 127, 0, 0, 2 }, arg, "explicit 127.0.0.2");
}

test "SONNY-1336 --listen-grpc 0.0.0.0:<port> listens on every interface" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const port = try test_ports.freeTcpPort();
    var arg_buf: [32]u8 = undefined;
    const arg = try std.fmt.bufPrint(&arg_buf, "0.0.0.0:{d}", .{port});
    var dial_buf: [32]u8 = undefined;
    const dial = try std.fmt.bufPrint(&dial_buf, "127.0.0.1:{d}", .{port});
    try expectListensOn(&.{ "--listen-grpc", arg }, port, .{ 0, 0, 0, 0 }, dial, "explicit 0.0.0.0");
}

test "SONNY-1336 --listen-grpc <port> alone binds the QUIC listener's address" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const port = try test_ports.freeTcpPort();
    const quic_port = try test_ports.freeUdpPort();
    var arg_buf: [8]u8 = undefined;
    const arg = try std.fmt.bufPrint(&arg_buf, "{d}", .{port});
    var quic_buf: [32]u8 = undefined;
    const quic = try std.fmt.bufPrint(&quic_buf, "127.0.0.3:{d}", .{quic_port});
    var dial_buf: [32]u8 = undefined;
    const dial = try std.fmt.bufPrint(&dial_buf, "127.0.0.3:{d}", .{port});
    try expectListensOn(&.{ "--listen", quic, "--listen-grpc", arg }, port, .{ 127, 0, 0, 3 }, dial, "port only with QUIC on 127.0.0.3");
}

test "SONNY-1336 --listen-grpc <port> alone without a QUIC listener binds 0.0.0.0 like QUIC's port-only form" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const port = try test_ports.freeTcpPort();
    var arg_buf: [8]u8 = undefined;
    const arg = try std.fmt.bufPrint(&arg_buf, "{d}", .{port});
    var dial_buf: [32]u8 = undefined;
    const dial = try std.fmt.bufPrint(&dial_buf, "127.0.0.1:{d}", .{port});
    try expectListensOn(&.{ "--listen-grpc", arg }, port, .{ 0, 0, 0, 0 }, dial, "port only, gRPC only");
}

test "SONNY-1336 a --listen-grpc address grpc-zig cannot bind, or a bad port, is refused at startup" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const port = try test_ports.freeTcpPort();
    var bufs: [4][48]u8 = undefined;
    const cases = [_][]const u8{
        try std.fmt.bufPrint(&bufs[0], "[::1]:{d}", .{port}),
        try std.fmt.bufPrint(&bufs[1], "grpc.example.invalid:{d}", .{port}),
        try std.fmt.bufPrint(&bufs[2], "127.0.0.1:{d}x", .{port}),
        try std.fmt.bufPrint(&bufs[3], "127.0.0.1:{d}", .{@as(u32, 70000)}),
    };
    var failures: usize = 0;
    for (cases) |arg| {
        var server = try Server.start(&.{ "--listen-grpc", arg });
        defer server.deinit();
        const t0 = nowMillis();
        while (nowMillis() - t0 < refusal_deadline_ms and !server.pollExit()) {
            server.drain();
            sleepMs(100);
        }
        var found: [8][13]u8 = undefined;
        const listening = try listenersOnPort(port, &found);
        const ok = server.reaped and server.exit_code != null and server.exit_code.? == 2 and
            server.saw("--listen-grpc") and server.saw(arg) and listening == 0;
        if (!ok) {
            failures += 1;
            std.debug.print("SONNY-1336 refusal case '{s}': exited={} code={any} listeners on {d}={d}\n", .{ arg, server.reaped, server.exit_code, port, listening });
            server.dump(arg);
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
