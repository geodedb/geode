// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6487 item 2, end to end against a real `geode serve`:
//   * `--listen [::1]:<port>` binds the IPv6 loopback and answers a query
//     from a QUIC client dialling `[::1]:<port>` (tests/proto_test_util.zig
//     -> src/transport/quic.zig QuicClient, the client the cluster also
//     dials peers with). Before, the test client split `[::1]:<port>` on the
//     last colon (host `[::1]`) and QuicClient bound an IPv4-only endpoint
//     and formatted the dial address without brackets.
//   * `--listen 127.0.0.1:<not a port>` refuses to start; it used to listen
//     on 0.0.0.0:3141 instead.
//   * `geode query --server [::1]:<port>` / `--server ip6-localhost:<port>`
//     says the CLI's QUIC client (geode-client-zig, which binds an IPv4-only
//     endpoint) cannot reach an IPv6 server yet, instead of failing with a
//     bare InvalidAddress; `--server localhost:<port>` resolves to IPv4.
//   * `geode --audit-syslog <host>:<not a port>` is refused; it used to send
//     to port 514. An IPv4 or bracketed IPv6 target receives the audit
//     datagram (127.0.0.1 used to be sent to 1.0.0.127: wrong byte order),
//     and a host name the sender cannot resolve is refused, not dropped.
// Skips (with a message) when the host has no IPv6 loopback.

const std = @import("std");
const builtin = @import("builtin");
const util = @import("proto_test_util.zig");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

fn ipv6LoopbackAvailable() bool {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const addr = std.Io.net.IpAddress.parse("::1", 0) catch return false;
    const socket = addr.bind(io, .{ .mode = .dgram, .protocol = .udp }) catch return false;
    socket.close(io);
    return true;
}

const Run = struct {
    code: ?u8,
    /// stdout and stderr, interleaved.
    output: []u8,

    fn deinit(self: Run, a: std.mem.Allocator) void {
        a.free(self.output);
    }
};

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Run `argv` with its output in a file and a hard deadline: past
/// `timeout_s` the child is killed (code null). `std.process.run`'s timeout
/// did not stop a `geode serve` that kept running.
fn runGeode(a: std.mem.Allocator, argv: []const []const u8, extra_env: []const [2][]const u8, timeout_s: i64) !Run {
    const linux = std.os.linux;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    for (extra_env) |kv| try env.put(kv[0], kv[1]);
    var dir = try test_scratch.ScratchDir.create("sonny6487-run");
    defer dir.remove();
    const out_path = try std.fmt.allocPrint(a, "{s}/run.out", .{dir.path()});
    defer a.free(out_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
    defer out.close(fsIo());
    const child = try std.process.spawn(threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .{ .file = out },
        .stderr = .{ .file = out },
    });
    const pid = child.id.?;
    var status: u32 = 0;
    var exited = false;
    var waited_ms: i64 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        if (rc == @as(usize, @intCast(pid))) {
            exited = true;
            break;
        }
        if (waited_ms >= timeout_s * 1000) {
            std.posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            break;
        }
        fsIo().sleep(.fromNanoseconds(100 * std.time.ns_per_ms), .awake) catch {};
        waited_ms += 100;
    }
    const code: ?u8 = if (exited and (status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else null;
    return .{ .code = code, .output = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, a, .limited(16 << 20)) };
}

test "SONNY-6487: geode serve --listen [::1]:<port> answers a query over IPv6" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (!ipv6LoopbackAvailable()) {
        std.debug.print("SKIP: this host has no IPv6 loopback (::1)\n", .{});
        return error.SkipZigTest;
    }
    const a = std.testing.allocator;
    const port = try util.getRandomPort();
    const addr = try std.fmt.allocPrint(a, "[::1]:{d}", .{port});
    var server = util.spawnServerWithAddr(a, addr, null) catch |err| {
        a.free(addr);
        return err;
    };
    server.port = port;
    server.addr = addr;
    defer server.deinit();
    try util.waitForServerReady(a, addr, 15_000);

    var client = try util.QuicProtoClient.connect(a, addr);
    defer client.deinit();
    var h = try client.hello(a, util.defaultUsername(), util.defaultPassword());
    defer h.deinit(a);
    try std.testing.expect(h.success);
    var res = try client.executeAndCollect(a, "RETURN 41 + 1 AS x", util.emptyParams(), 16);
    defer res.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expect(util.testValueEqual(.{ .int = 42 }, res.rows[0][0]));

    // The CLI client (geode-client-zig) binds an IPv4-only QUIC endpoint: it
    // refuses an IPv6 server with that reason instead of a bare
    // InvalidAddress from a mis-split dial address.
    const exe = geode_test_bin.geode_exe;
    var targets: [2][]const u8 = .{ addr, "" };
    var n_targets: usize = 1;
    const by_name = try std.fmt.allocPrint(a, "ip6-localhost:{d}", .{port});
    defer a.free(by_name);
    if (hostsFileNames("ip6-localhost")) {
        targets[1] = by_name;
        n_targets = 2;
    }
    for (targets[0..n_targets]) |target| {
        const r = try runGeode(a, &.{ exe, "query", "--server", target, "--insecure", "--no-saved-session", "-U", util.defaultUsername(), "-P", util.defaultPassword(), "--timeout", "10", "RETURN 1 AS x" }, &.{}, 60);
        defer r.deinit(a);
        if (r.code == 0 or std.mem.indexOf(u8, r.output, "IPv6") == null) {
            std.debug.print("query --server {s}: code {?d}\noutput:\n{s}\n", .{ target, r.code, r.output });
            return error.TestUnexpectedResult;
        }
    }
}

fn hostsFileNames(name: []const u8) bool {
    var buf: [16 * 1024]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = std.Io.Dir.cwd().readFile(io, "/etc/hosts", &buf) catch return false;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const ip = fields.next() orelse continue;
        if (ip[0] == '#') continue;
        while (fields.next()) |f| if (std.mem.eql(u8, f, name)) return true;
    }
    return false;
}

test "SONNY-6487: geode serve refuses a --listen port that is not a port" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const data_dir = try std.fmt.allocPrint(a, "{s}/sonny6487-listen-refused", .{try test_scratch.processRoot()});
    defer a.free(data_dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), data_dir);
    const r = try runGeode(a, &.{ geode_test_bin.geode_exe, "serve", "--listen", "127.0.0.1:quic", "--data-dir", data_dir }, &.{
        .{ "GEODE_ADMIN_USERNAME", util.defaultUsername() },
        .{ "GEODE_ADMIN_PASSWORD", util.defaultPassword() },
    }, 20);
    defer r.deinit(a);
    if (r.code == null or r.code.? == 0 or std.mem.indexOf(u8, r.output, "127.0.0.1:quic") == null) {
        std.debug.print("serve --listen 127.0.0.1:quic: code {?d}\noutput tail:\n{s}\n", .{ r.code, r.output[r.output.len -| 2000..] });
        return error.TestUnexpectedResult;
    }
}

test "SONNY-6487: geode --audit-syslog refuses a port that is not a port instead of using 514" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const r = try runGeode(a, &.{ geode_test_bin.geode_exe, "--audit-syslog", "127.0.0.1:syslog", "completion", "bash" }, &.{}, 30);
    defer r.deinit(a);
    if (r.code == null or r.code.? == 0 or std.mem.indexOf(u8, r.output, "127.0.0.1:syslog") == null) {
        std.debug.print("--audit-syslog 127.0.0.1:syslog: code {?d}\noutput:\n{s}\n", .{ r.code, r.output });
        return error.TestUnexpectedResult;
    }
    // A host name the sender cannot resolve is refused (it used to be
    // accepted and every audit message silently dropped).
    const named = try runGeode(a, &.{ geode_test_bin.geode_exe, "--audit-syslog", "syslog.invalid:514", "completion", "bash" }, &.{}, 30);
    defer named.deinit(a);
    if (named.code == null or named.code.? == 0) {
        std.debug.print("--audit-syslog syslog.invalid:514: code {?d}\noutput:\n{s}\n", .{ named.code, named.output });
        return error.TestUnexpectedResult;
    }
}

/// A UDP receiver on `ip` (an IPv4 or IPv6 literal) at a kernel-chosen port.
const UdpReceiver = struct {
    fd: i32,
    port: u16,

    fn open(ip: []const u8) !UdpReceiver {
        const linux = std.os.linux;
        const addr = try std.Io.net.IpAddress.parse(ip, 0);
        const v6 = addr == .ip6;
        const rc = linux.socket(if (v6) linux.AF.INET6 else linux.AF.INET, linux.SOCK.DGRAM, 0);
        if (@as(isize, @bitCast(rc)) < 0) return error.SocketFailed;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);
        var storage: linux.sockaddr.storage = std.mem.zeroes(linux.sockaddr.storage);
        var len: linux.socklen_t = 0;
        switch (addr) {
            .ip4 => |a4| {
                const sa: *linux.sockaddr.in = @ptrCast(&storage);
                sa.* = .{ .port = 0, .addr = std.mem.readInt(u32, &a4.bytes, .little) };
                len = @sizeOf(linux.sockaddr.in);
            },
            .ip6 => |a6| {
                const sa: *linux.sockaddr.in6 = @ptrCast(&storage);
                sa.* = .{ .port = 0, .flowinfo = 0, .addr = a6.bytes, .scope_id = 0 };
                len = @sizeOf(linux.sockaddr.in6);
            },
        }
        if (linux.errno(linux.bind(fd, @ptrCast(&storage), len)) != .SUCCESS) return error.BindFailed;
        var got: linux.socklen_t = @sizeOf(linux.sockaddr.storage);
        if (linux.errno(linux.getsockname(fd, @ptrCast(&storage), &got)) != .SUCCESS) return error.GetSockNameFailed;
        const port_be: u16 = if (v6) @as(*linux.sockaddr.in6, @ptrCast(&storage)).port else @as(*linux.sockaddr.in, @ptrCast(&storage)).port;
        return .{ .fd = fd, .port = std.mem.bigToNative(u16, port_be) };
    }

    /// Every datagram already queued, concatenated (non-blocking).
    fn drain(self: UdpReceiver, buf: []u8) []const u8 {
        const linux = std.os.linux;
        var n: usize = 0;
        while (n < buf.len) {
            const rc = linux.recvfrom(self.fd, buf[n..].ptr, buf.len - n, linux.MSG.DONTWAIT, null, null);
            if (@as(isize, @bitCast(rc)) <= 0) break;
            n += rc;
        }
        return buf[0..n];
    }

    fn close(self: UdpReceiver) void {
        _ = std.os.linux.close(self.fd);
    }
};

test "SONNY-6487: --audit-syslog delivers to the IPv4 and the IPv6 address given" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var cases: [2][]const u8 = .{ "127.0.0.1", "::1" };
    const n_cases: usize = if (ipv6LoopbackAvailable()) 2 else 1;
    for (cases[0..n_cases]) |ip| {
        const rx = try UdpReceiver.open(ip);
        defer rx.close();
        const target = if (std.mem.indexOfScalar(u8, ip, ':') != null)
            try std.fmt.allocPrint(a, "[{s}]:{d}", .{ ip, rx.port })
        else
            try std.fmt.allocPrint(a, "{s}:{d}", .{ ip, rx.port });
        defer a.free(target);
        const r = try runGeode(a, &.{ geode_test_bin.geode_exe, "--audit-syslog", target, "completion", "bash" }, &.{}, 30);
        defer r.deinit(a);
        var buf: [16 * 1024]u8 = undefined;
        const got = rx.drain(&buf);
        if (r.code == null or r.code.? != 0 or std.mem.indexOf(u8, got, "action=startup") == null) {
            std.debug.print("--audit-syslog {s}: code {?d}, received {d} bytes: {s}\noutput:\n{s}\n", .{ target, r.code, got.len, got, r.output });
            return error.TestUnexpectedResult;
        }
    }
}
