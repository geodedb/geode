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
// addresses (127.0.0.43 and 127.0.0.44, both loopback on Linux, bound as the
// clients' source addresses; macOS uses 127.0.0.1 and ::1, its configured
// loopback addresses): at the cap,
// one peer's Handshake is refused while the other's is served.
//
// CANARY: REQ=REQ-SONNY-3313-GRPC-PEER-IP; FEATURE="GrpcSessionLifetime"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3313_grpc_peer_ip.zig; OWNER=transport; UPDATED=2026-09-28

const std = @import("std");
const testing = std.testing;
const libc = std.c;
const ipv6_peer_b = @import("builtin").os.tag == .macos;
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

fn check(rc: c_int) !c_int {
    const e = libc.errno(rc);
    if (e != .SUCCESS) {
        std.debug.print("syscall failed: {s}\n", .{@tagName(e)});
        return error.Syscall;
    }
    return rc;
}

fn openSocket(family: u32) !i32 {
    // Darwin has no SOCK_CLOEXEC flag; set the descriptor flag portably.
    const fd = try check(libc.socket(family, libc.SOCK.STREAM, 0));
    errdefer _ = libc.close(fd);
    _ = try check(libc.fcntl(fd, libc.F.SETFD, @as(c_int, libc.FD_CLOEXEC)));
    return fd;
}

/// A listening TCP socket on `addr` (port 0: the kernel picks), and its port.
fn listenOn(family: u32, addr: *posix.sockaddr.storage, len: posix.socklen_t) !struct { fd: i32, addr: posix.sockaddr.storage } {
    const fd = try openSocket(family);
    errdefer _ = libc.close(fd);
    _ = try check(libc.bind(fd, @ptrCast(addr), len));
    _ = try check(libc.listen(fd, 16));
    var bound: posix.sockaddr.storage = undefined;
    var blen: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    _ = try check(libc.getsockname(fd, @ptrCast(&bound), &blen));
    return .{ .fd = fd, .addr = bound };
}

/// Connect from source address `src` (bound first) to `dst`, and accept on
/// `listen_fd`: the server side of the connection.
fn connectFrom(family: u32, src: *posix.sockaddr.storage, dst: *posix.sockaddr.storage, len: posix.socklen_t, listen_fd: i32) !struct { client: i32, server: i32 } {
    const client = try openSocket(family);
    errdefer _ = libc.close(client);
    _ = try check(libc.bind(client, @ptrCast(src), len));
    _ = try check(libc.connect(client, @ptrCast(dst), len));
    const server = try check(libc.accept(listen_fd, null, null));
    errdefer _ = libc.close(server);
    _ = try check(libc.fcntl(server, libc.F.SETFD, @as(c_int, libc.FD_CLOEXEC)));
    return .{ .client = client, .server = server };
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
    const l = try listenOn(libc.AF.INET, &any, @sizeOf(posix.sockaddr.in));
    defer _ = libc.close(l.fd);
    var dst = l.addr;
    var fds: std.ArrayList(i32) = .empty;
    defer {
        for (fds.items) |fd| _ = libc.close(fd);
        fds.deinit(testing.allocator);
    }

    // Peer A: two sessions, each in an open transaction.
    const peer_a = if (ipv6_peer_b) "127.0.0.1" else "127.0.0.43";
    const principal_a = "anonymous@" ++ peer_a;
    var src_a = v4(127, 0, 0, if (ipv6_peer_b) 1 else 43, 0);
    var a_sessions: [2][]const u8 = undefined;
    for (&a_sessions) |*sess| {
        const conn = try connectFrom(libc.AF.INET, &src_a, &dst, @sizeOf(posix.sockaddr.in), l.fd);
        try fds.appendSlice(testing.allocator, &.{ conn.client, conn.server });
        const peer = try peerText(conn.server);
        defer testing.allocator.free(peer);
        try testing.expectEqualStrings(peer_a, peer);
        const hello = try handshake(ga, conn.server);
        if (!hello.success) std.debug.print("A: {s}\n", .{hello.error_message});
        try testing.expect(hello.success);
        sess.* = hello.session_id;
        try fx.begin(ga, sess.*);
    }
    try testing.expectEqual(@as(usize, 2), store.principalSessionCount(principal_a));
    try testing.expectEqual(@as(usize, 0), store.principalSessionCount("anonymous@unknown"));

    // A third from A: refused (its sessions are in transactions).
    {
        const conn = try connectFrom(libc.AF.INET, &src_a, &dst, @sizeOf(posix.sockaddr.in), l.fd);
        try fds.appendSlice(testing.allocator, &.{ conn.client, conn.server });
        const hello = try handshake(ga, conn.server);
        try testing.expect(!hello.success);
        try testing.expect(std.mem.startsWith(u8, hello.error_message, "RESOURCE_EXHAUSTED"));
    }
    // Peer B: served; A's cap is A's alone. macOS configures only one
    // IPv4 loopback address, so require a second real peer over IPv6 there.
    const peer_b = if (ipv6_peer_b) "0000:0000:0000:0000:0000:0000:0000:0001" else "127.0.0.44";
    var src_b = if (ipv6_peer_b)
        v6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 0)
    else
        v4(127, 0, 0, 44, 0);
    {
        const family = if (ipv6_peer_b) libc.AF.INET6 else libc.AF.INET;
        const len = if (ipv6_peer_b) @sizeOf(posix.sockaddr.in6) else @sizeOf(posix.sockaddr.in);
        const listener = if (ipv6_peer_b) try listenOn(family, &src_b, len) else l;
        defer if (ipv6_peer_b) {
            _ = libc.close(listener.fd);
        };
        var destination = listener.addr;
        const conn = try connectFrom(family, &src_b, &destination, len, listener.fd);
        try fds.appendSlice(testing.allocator, &.{ conn.client, conn.server });
        const peer = try peerText(conn.server);
        defer testing.allocator.free(peer);
        try testing.expectEqualStrings(peer_b, peer);
        const hello = try handshake(ga, conn.server);
        if (!hello.success) std.debug.print("B: {s}\n", .{hello.error_message});
        try testing.expect(hello.success);
        try testing.expectEqual(@as(usize, 1), store.principalSessionCount("anonymous@" ++ peer_b));
    }
    // Linux also checks IPv6 when available; macOS already required it above.
    if (!ipv6_peer_b) blk: {
        var any6 = v6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 0);
        const l6 = listenOn(libc.AF.INET6, &any6, @sizeOf(posix.sockaddr.in6)) catch {
            std.debug.print("SONNY-3313: no IPv6 loopback here; the IPv6 case is skipped\n", .{});
            break :blk;
        };
        defer _ = libc.close(l6.fd);
        var dst6 = l6.addr;
        var src6 = v6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 0);
        const conn = try connectFrom(libc.AF.INET6, &src6, &dst6, @sizeOf(posix.sockaddr.in6), l6.fd);
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

// SONNY-6645: a gRPC Handshake past the tenant's connection quota is refused
// as QUIC refuses it: the quota is a resource limit, 53300 (class 53,
// implementation-defined; ISO/IEC 39075 Table 8 has no resource class). The
// Handshake answered a bare internal error (`error.OutOfMemory`, raised for
// the quota) with no SQLSTATE, and QUIC sent 42000.
fn handshakeTenant(ga: std.mem.Allocator, server: i32, tenant: []const u8) !schema.HelloResponse {
    var trans: grpc.GrpcTransport = .{
        .stream = .{ .socket = .{ .handle = server, .address = undefined } },
        .io = std.Io.Threaded.global_single_threaded.io(),
        .allocator = ga,
        .last_stream_id = 1,
    };
    const req = try fx.encodeProto(ga, schema.HelloRequest{ .username = "", .password = "", .client_name = "sonny6645", .tenant_id = tenant });
    return fx.decodeProto(schema.HelloResponse, ga, try grpc.handleHandshake(req, &trans, ga));
}

test "SONNY-6645: a gRPC Handshake past the tenant's connection quota is refused with 53300, as QUIC refuses it" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    var qm = geode.tenant_quota.TenantQuotaManager.init(testing.allocator);
    defer qm.deinit();
    try qm.setQuota("tenant-6645", .{ .max_connections = 1 });
    const prev = geode.tenant_quota.getGlobalQuotaManager();
    geode.tenant_quota.setGlobalQuotaManager(&qm);
    defer geode.tenant_quota.setGlobalQuotaManager(prev);

    var any = v4(127, 0, 0, 1, 0);
    const l = try listenOn(libc.AF.INET, &any, @sizeOf(posix.sockaddr.in));
    defer _ = libc.close(l.fd);
    var dst = l.addr;
    var src = v4(127, 0, 0, 1, 0);
    var fds: std.ArrayList(i32) = .empty;
    defer {
        for (fds.items) |fd| _ = libc.close(fd);
        fds.deinit(testing.allocator);
    }

    const first_conn = try connectFrom(libc.AF.INET, &src, &dst, @sizeOf(posix.sockaddr.in), l.fd);
    try fds.appendSlice(testing.allocator, &.{ first_conn.client, first_conn.server });
    const first = try handshakeTenant(ga, first_conn.server, "tenant-6645");
    if (!first.success) std.debug.print("first: {s}\n", .{first.error_message});
    try testing.expect(first.success);
    try testing.expectEqual(@as(u32, 1), qm.getUsage("tenant-6645").connections);

    const second_conn = try connectFrom(libc.AF.INET, &src, &dst, @sizeOf(posix.sockaddr.in), l.fd);
    try fds.appendSlice(testing.allocator, &.{ second_conn.client, second_conn.server });
    const second = try handshakeTenant(ga, second_conn.server, "tenant-6645");
    try testing.expect(!second.success);
    try testing.expectEqualStrings("53300: Connection quota exceeded for tenant", second.error_message);
    try testing.expectEqualStrings("53300", geode.proto_util.mapError(error.TenantConnectionQuotaExceeded).code);
    // The refused Handshake holds none of the quota.
    try testing.expectEqual(@as(u32, 1), qm.getUsage("tenant-6645").connections);
}
