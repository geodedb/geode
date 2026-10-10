// SONNY-3313 regression (round 16, I1): the gRPC Handshake keys a client by
// its real peer address.
//
// `grpc_server.getPeerIp` was a Zig 0.16 placeholder that answered "unknown"
// for every peer. Every anonymous client was `anonymous@unknown` and every
// federation peer `federation@unknown`, so with the round 15 cap (a session
// in an open transaction is never closed; SONNY-3252) one host holding its
// sessions in transactions refused every other host's Handshake
// (RESOURCE_EXHAUSTED); and the auth rate limiter's per-IP bucket was one
// bucket for every client. The round 15 tests passed only because they
// called `principalFor` with an address of their own.
//
// Here: `formatPeerIp` on IPv4, IPv6 and IPv4-mapped addresses; and the real
// Handshake handler serving real accepted TCP sockets from two peer
// addresses (127.0.0.2 and 127.0.0.3, both loopback on Linux, bound as the
// clients' source addresses; and ::1 when the host has IPv6): at the cap,
// one peer's Handshake is refused while the other's is served.
//
// CANARY: REQ=REQ-SONNY-3313-GRPC-PEER-IP; FEATURE="GrpcSessionLifetime"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3313_grpc_peer_ip.zig; OWNER=transport; UPDATED=2026-09-28

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const posix = std.posix;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

fn v4(a: u8, b: u8, c: u8, d: u8, port: u16) posix.sockaddr.storage {
    var st: posix.sockaddr.storage = std.mem.zeroes(posix.sockaddr.storage);
    const in4: *posix.sockaddr.in = @ptrCast(@alignCast(&st));
    in4.* = .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast([4]u8{ a, b, c, d }) };
    return st;
}

fn v6(bytes: [16]u8, port: u16) posix.sockaddr.storage {
    var st: posix.sockaddr.storage = std.mem.zeroes(posix.sockaddr.storage);
    const in6: *posix.sockaddr.in6 = @ptrCast(@alignCast(&st));
    in6.* = .{ .port = std.mem.nativeToBig(u16, port), .flowinfo = 0, .addr = bytes, .scope_id = 0 };
    return st;
}

test "SONNY-3313: formatPeerIp formats IPv4, IPv6 and IPv4-mapped addresses (not \"unknown\")" {
    var buf: [45]u8 = undefined;
    var a = v4(127, 0, 0, 1, 5000);
    try testing.expectEqualStrings("127.0.0.1", grpc.formatPeerIp(&buf, &a, @sizeOf(posix.sockaddr.in)));
    a = v4(10, 20, 255, 7, 1);
    try testing.expectEqualStrings("10.20.255.7", grpc.formatPeerIp(&buf, &a, @sizeOf(posix.sockaddr.in)));
    var b = v6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 5000);
    try testing.expectEqualStrings("0000:0000:0000:0000:0000:0000:0000:0001", grpc.formatPeerIp(&buf, &b, @sizeOf(posix.sockaddr.in6)));
    b = v6(.{ 0x20, 0x01, 0x0d, 0xb8, 0xab, 0xcd, 0, 0x12, 0, 0, 0, 0, 0xde, 0xad, 0xbe, 0xef }, 1);
    try testing.expectEqualStrings("2001:0db8:abcd:0012:0000:0000:dead:beef", grpc.formatPeerIp(&buf, &b, @sizeOf(posix.sockaddr.in6)));
    // A dual-stack listener's IPv4 client: its IPv4 form.
    b = v6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 1, 9 }, 1);
    try testing.expectEqualStrings("192.168.1.9", grpc.formatPeerIp(&buf, &b, @sizeOf(posix.sockaddr.in6)));
    // A family it does not know, or a short address.
    var u: posix.sockaddr.storage = std.mem.zeroes(posix.sockaddr.storage);
    u.family = posix.AF.UNIX;
    try testing.expectEqualStrings("unknown", grpc.formatPeerIp(&buf, &u, @sizeOf(posix.sockaddr.storage)));
    a = v4(127, 0, 0, 1, 1);
    try testing.expectEqualStrings("unknown", grpc.formatPeerIp(&buf, &a, 4));
}

fn check(rc: usize) !usize {
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        std.debug.print("syscall failed: {s}\n", .{@tagName(e)});
        return error.Syscall;
    }
    return rc;
}

/// A listening TCP socket on `addr` (port 0: the kernel picks), and its port.
fn listenOn(family: u32, addr: *posix.sockaddr.storage, len: posix.socklen_t) !struct { fd: i32, addr: posix.sockaddr.storage } {
    const fd: i32 = @intCast(try check(linux.socket(family, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    errdefer _ = linux.close(fd);
    _ = try check(linux.bind(fd, @ptrCast(addr), len));
    _ = try check(linux.listen(fd, 16));
    var bound: posix.sockaddr.storage = undefined;
    var blen: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    _ = try check(linux.getsockname(fd, @ptrCast(&bound), &blen));
    return .{ .fd = fd, .addr = bound };
}

/// Connect from source address `src` (bound first) to `dst`, and accept on
/// `listen_fd`: the server side of the connection.
fn connectFrom(family: u32, src: *posix.sockaddr.storage, dst: *posix.sockaddr.storage, len: posix.socklen_t, listen_fd: i32) !struct { client: i32, server: i32 } {
    const c: i32 = @intCast(try check(linux.socket(family, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    errdefer _ = linux.close(c);
    _ = try check(linux.bind(c, @ptrCast(src), len));
    _ = try check(linux.connect(c, @ptrCast(dst), len));
    const s: i32 = @intCast(try check(linux.accept(listen_fd, null, null)));
    return .{ .client = c, .server = s };
}

fn peerText(fd: i32) ![]const u8 {
    const buf = grpc.peerIpOfSocket(fd);
    return testing.allocator.dupe(u8, std.mem.sliceTo(&buf, 0));
}

/// A Handshake served by the real handler on the accepted socket `server`.
fn handshake(ga: std.mem.Allocator, server: i32) !schema.HelloResponse {
    var trans: grpc.GrpcTransport = .{
        .stream = .{ .socket = .{ .handle = server, .address = undefined } },
        .io = std.Io.Threaded.global_single_threaded.io(),
        .allocator = ga,
        .last_stream_id = 1,
    };
    const req = try fx.encodeProto(ga, schema.HelloRequest{ .username = "", .password = "", .client_name = "sonny3313" });
    return fx.decodeProto(schema.HelloResponse, ga, try grpc.handleHandshake(req, &trans, ga));
}

test "SONNY-3313: over real sockets, anonymous Handshakes from two peer addresses count per peer: at the cap one peer is refused, the other served" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    var store = grpc.SessionStore.init(ga, .{ .idle_in_transaction_timeout_ms = 0, .session_idle_timeout_ms = 0, .max_sessions_per_principal = 2 });
    grpc.setSessionStore(&store);
    defer {
        grpc.setSessionStore(&f.sessions);
        store.deinit();
    }

    var any = v4(127, 0, 0, 1, 0);
    const l = try listenOn(linux.AF.INET, &any, @sizeOf(posix.sockaddr.in));
    defer _ = linux.close(l.fd);
    var dst = l.addr;
    var fds: std.ArrayList(i32) = .empty;
    defer {
        for (fds.items) |fd| _ = linux.close(fd);
        fds.deinit(testing.allocator);
    }

    // Peer A (127.0.0.2): two sessions, each in an open transaction.
    var src_a = v4(127, 0, 0, 2, 0);
    var a_sessions: [2][]const u8 = undefined;
    for (&a_sessions) |*sess| {
        const conn = try connectFrom(linux.AF.INET, &src_a, &dst, @sizeOf(posix.sockaddr.in), l.fd);
        try fds.appendSlice(testing.allocator, &.{ conn.client, conn.server });
        const peer = try peerText(conn.server);
        defer testing.allocator.free(peer);
        try testing.expectEqualStrings("127.0.0.2", peer);
        const hello = try handshake(ga, conn.server);
        if (!hello.success) std.debug.print("A: {s}\n", .{hello.error_message});
        try testing.expect(hello.success);
        sess.* = hello.session_id;
        try fx.begin(ga, sess.*);
    }
    try testing.expectEqual(@as(usize, 2), store.principalSessionCount("anonymous@127.0.0.2"));
    try testing.expectEqual(@as(usize, 0), store.principalSessionCount("anonymous@unknown"));

    // A third from A: refused (its sessions are in transactions).
    {
        const conn = try connectFrom(linux.AF.INET, &src_a, &dst, @sizeOf(posix.sockaddr.in), l.fd);
        try fds.appendSlice(testing.allocator, &.{ conn.client, conn.server });
        const hello = try handshake(ga, conn.server);
        try testing.expect(!hello.success);
        try testing.expect(std.mem.startsWith(u8, hello.error_message, "RESOURCE_EXHAUSTED"));
    }
    // Peer B (127.0.0.3): served; A's cap is A's alone.
    var src_b = v4(127, 0, 0, 3, 0);
    {
        const conn = try connectFrom(linux.AF.INET, &src_b, &dst, @sizeOf(posix.sockaddr.in), l.fd);
        try fds.appendSlice(testing.allocator, &.{ conn.client, conn.server });
        const peer = try peerText(conn.server);
        defer testing.allocator.free(peer);
        try testing.expectEqualStrings("127.0.0.3", peer);
        const hello = try handshake(ga, conn.server);
        if (!hello.success) std.debug.print("B: {s}\n", .{hello.error_message});
        try testing.expect(hello.success);
        try testing.expectEqual(@as(usize, 1), store.principalSessionCount("anonymous@127.0.0.3"));
    }
    // And over IPv6 loopback, when the host has it.
    blk: {
        var any6 = v6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 0);
        const l6 = listenOn(linux.AF.INET6, &any6, @sizeOf(posix.sockaddr.in6)) catch {
            std.debug.print("SONNY-3313: no IPv6 loopback here; the IPv6 case is skipped\n", .{});
            break :blk;
        };
        defer _ = linux.close(l6.fd);
        var dst6 = l6.addr;
        var src6 = v6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 0);
        const conn = try connectFrom(linux.AF.INET6, &src6, &dst6, @sizeOf(posix.sockaddr.in6), l6.fd);
        try fds.appendSlice(testing.allocator, &.{ conn.client, conn.server });
        const peer = try peerText(conn.server);
        defer testing.allocator.free(peer);
        try testing.expectEqualStrings("0000:0000:0000:0000:0000:0000:0000:0001", peer);
        const hello = try handshake(ga, conn.server);
        try testing.expect(hello.success);
        try testing.expectEqual(@as(usize, 1), store.principalSessionCount("anonymous@0000:0000:0000:0000:0000:0000:0000:0001"));
    }
    for (a_sessions) |sess| try testing.expect(try fx.commit(ga, sess));
}
