// SONNY-6301: test servers on free ports, and shared test clients that wait
// for a live server instead of failing at a fixed reply deadline.
//
// (1) tests/gql_conformance.zig started every server on 127.0.0.1:3181, so
// two runs on one host talked to each other's server (HELLO timeouts, a seed
// refused with "42P07 Duplicate graph name"). Tests now take a port from
// tests/test_ports.zig. Covered here: the helper hands out distinct, usable
// UDP and TCP ports, and two servers started through it at once both answer
// on their own port.
//
// (2) The shared clients failed at fixed short deadlines: QuicProtoClient
// `backup` 10 s (test-sonny6288-server-restore-target, 2 of 5 runs under
// load), the 5 s HELLO / 5 s query read (test-new1-cross-graph-bola's admin
// setup), the 5 s gRPC socket timeout. A QuicProtoClient connected to a
// loopback address now treats its deadline as soft and keeps waiting while
// the server still holds its port, up to `liveness_cap_ns`, and fails at
// once with error.ServerExited when the port is released (the server
// exited); the gRPC client's read timeout is the same cap, and TCP reports a
// server that exited at once. Covered here with the real server stopped
// (SIGSTOP) for longer than the old deadline, then resumed, and killed.
const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const test_ports = @import("test_ports.zig");
const scratch = @import("test_scratch.zig");
const posix = std.posix;

fn monoMs() u64 {
    var ts: posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

test "SONNY-6301: free UDP and TCP ports are distinct and usable" {
    const io = std.Io.Threaded.global_single_threaded.io();

    const a = try test_ports.freeUdpPort();
    const b = try test_ports.freeUdpPortExcept(&.{a});
    try std.testing.expect(a != 0 and b != 0 and a != b);
    // Both can be bound for UDP, at the same time, the way two QUIC servers
    // started by two concurrent test runs bind them.
    const addr_a = try std.Io.net.IpAddress.parse("127.0.0.1", a);
    const addr_b = try std.Io.net.IpAddress.parse("127.0.0.1", b);
    const sa = try addr_a.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer sa.close(io);
    const sb = try addr_b.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer sb.close(io);

    const t = try test_ports.freeTcpPortExcept(&.{ a, b });
    try std.testing.expect(t != 0 and t != a and t != b);
    const addr_t = try std.Io.net.IpAddress.parse("127.0.0.1", t);
    var listener = try addr_t.listen(io, .{});
    listener.deinit(io);
}

test "SONNY-6301: udpPortHeld reports a held port and a released one" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const port = try test_ports.freeUdpPort();
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const sock = try addr.bind(io, .{ .mode = .dgram, .protocol = .udp });
    try std.testing.expectEqual(test_ports.Held.held, test_ports.udpPortHeld(addr));
    sock.close(io);
    try std.testing.expectEqual(test_ports.Held.free, test_ports.udpPortHeld(addr));

    try std.testing.expect(test_ports.isLoopback(addr));
    try std.testing.expect(test_ports.isLoopback(try std.Io.net.IpAddress.parse("::1", port)));
    try std.testing.expect(!test_ports.isLoopback(try std.Io.net.IpAddress.parse("10.0.0.1", port)));
}

const Server = struct {
    handle: util.ServerHandle,
    dir: scratch.ScratchDir,
    addr: []u8,
    grpc_addr: ?[]u8,
    port: u16,

    /// `geode serve` on a free port (and a free gRPC port), with its own
    /// data dir, ready for QUIC (and gRPC) clients.
    fn start(allocator: std.mem.Allocator, with_grpc: bool, avoid: []const u16) !Server {
        const port = try test_ports.freeUdpPortExcept(avoid);
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var grpc_addr: ?[]u8 = null;
        errdefer if (grpc_addr) |g| allocator.free(g);
        if (with_grpc) grpc_addr = try util.formatAddr(allocator, try test_ports.freeTcpPortExcept(&.{port}));

        var dir = try scratch.ScratchDir.create("sonny6301");
        errdefer dir.remove();
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", dir.path() });
        if (grpc_addr) |g| try argv.appendSlice(allocator, &.{ "--listen-grpc", g });
        var handle = try util.spawnServer(allocator, argv.items, if (with_grpc) util.TestEnv.grpcPlaintext() else null);
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, addr, 60_000);
        if (grpc_addr) |g| try util.waitForGrpcServerReady(allocator, g, 60_000);
        return .{ .handle = handle, .dir = dir, .addr = addr, .grpc_addr = grpc_addr, .port = port };
    }

    fn pid(self: *const Server) posix.pid_t {
        return self.handle.child.id.?;
    }

    fn stop(self: *Server, allocator: std.mem.Allocator) void {
        if (self.handle.child.id) |p| posix.kill(p, .CONT) catch {};
        self.handle.deinit();
        self.dir.remove();
        allocator.free(self.addr);
        if (self.grpc_addr) |g| allocator.free(g);
    }
};

fn connectHello(allocator: std.mem.Allocator, addr: []const u8) !util.QuicProtoClient {
    var client = try util.QuicProtoClient.connect(allocator, addr);
    errdefer client.deinit();
    var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer h.deinit(allocator);
    if (!h.success) return error.HelloFailed;
    return client;
}

test "SONNY-6301: two servers started at once get distinct ports and each answers on its own" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var s1 = try Server.start(allocator, false, &.{});
    defer s1.stop(allocator);
    var s2 = try Server.start(allocator, false, &.{s1.port});
    defer s2.stop(allocator);
    try std.testing.expect(s1.port != s2.port);

    // A graph created on one server does not exist on the other: each client
    // reached its own server (the collision answered "42P07 Duplicate graph
    // name" for a graph another run had created).
    var c1 = try connectHello(allocator, s1.addr);
    defer c1.deinit();
    var c2 = try connectHello(allocator, s2.addr);
    defer c2.deinit();
    var r1 = try c1.executeAndCollect(allocator, "CREATE GRAPH sonny6301_g", util.emptyParams(), 16);
    defer r1.deinit(allocator);
    try std.testing.expect(r1.error_code == null);
    var r2 = try c2.executeAndCollect(allocator, "CREATE GRAPH sonny6301_g", util.emptyParams(), 16);
    defer r2.deinit(allocator);
    if (r2.error_code) |code| {
        std.debug.print("second server refused the graph: {s} {s}\n", .{ code, r2.error_message orelse "" });
        return error.ServersShareState;
    }
}

fn resumeAfter(pid: posix.pid_t, ms: u64) void {
    sleepMs(ms);
    posix.kill(pid, .CONT) catch {};
}

test "SONNY-6301: a QUIC reply from a live server slower than the old deadline is waited for" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var server = try Server.start(allocator, false, &.{});
    defer server.stop(allocator);
    var client = try connectHello(allocator, server.addr);
    defer client.deinit();

    // `ping` reads its reply with a 2 s deadline. The server is stopped for
    // 3.5 s: alive, holding its port, answering late.
    try posix.kill(server.pid(), .STOP);
    const resumer = try std.Thread.spawn(.{}, resumeAfter, .{ server.pid(), 3_500 });
    defer resumer.join();
    const t0 = monoMs();
    const ok = client.ping(allocator) catch |err| {
        std.debug.print("ping against a stopped-then-resumed server failed after {d} ms: {s}\n", .{ monoMs() - t0, @errorName(err) });
        return err;
    };
    try std.testing.expect(ok);
    try std.testing.expect(monoMs() - t0 >= 3_000);
}

test "SONNY-6301: a QUIC reply wait fails at once when the server has exited" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var server = try Server.start(allocator, false, &.{});
    defer server.stop(allocator);
    var client = try connectHello(allocator, server.addr);
    defer client.deinit();

    const pid = server.pid();
    try posix.kill(pid, .KILL);
    while (util.processAlive(pid)) sleepMs(10);

    // `executeAndCollect` reads with a 5 s deadline; a server that is gone
    // must fail it well before that, and not as a plain timeout.
    const t0 = monoMs();
    if (client.executeAndCollect(allocator, "RETURN 1 AS x", util.emptyParams(), 16)) |res| {
        var r = res;
        r.deinit(allocator);
        return error.ReplyFromKilledServer;
    } else |err| {
        const elapsed = monoMs() - t0;
        if (err == error.Timeout or elapsed >= 4_000) {
            std.debug.print("query against a killed server failed after {d} ms with {s}\n", .{ elapsed, @errorName(err) });
            return error.DeadServerNotDetected;
        }
    }
}

test "SONNY-6301: a gRPC reply from a live server slower than the old 5 s socket timeout is waited for" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // SONNY-6782: plaintext gRPC is served in Debug only.
    if (!util.grpc_plaintext_served) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var server = try Server.start(allocator, true, &.{});
    defer server.stop(allocator);

    var client = try util.GrpcProtoClient.connect(allocator, server.grpc_addr.?);
    defer client.deinit();
    var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer h.deinit(allocator);
    try std.testing.expect(h.success);

    try posix.kill(server.pid(), .STOP);
    const resumer = try std.Thread.spawn(.{}, resumeAfter, .{ server.pid(), 6_500 });
    defer resumer.join();
    const t0 = monoMs();
    var res = client.executeAndCollect(allocator, "RETURN 1 AS x", util.emptyParams(), 16) catch |err| {
        std.debug.print("gRPC query against a stopped-then-resumed server failed after {d} ms: {s}\n", .{ monoMs() - t0, @errorName(err) });
        return err;
    };
    defer res.deinit(allocator);
    try std.testing.expect(res.error_code == null);
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
}
