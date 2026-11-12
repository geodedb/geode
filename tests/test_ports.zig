//! Free loopback ports for tests that start a listener (SONNY-6301).
//!
//! A test that starts `geode serve` on a fixed address (gql_conformance used
//! 127.0.0.1:3181) talks to whatever else holds that port: a second run of
//! the same test on the host (parallel lanes, the pre-push shards, CI jobs
//! sharing a runner) answered its HELLO, or refused its seed with "42P07
//! Duplicate graph name". `geode serve --listen 127.0.0.1:0` binds an
//! ephemeral port but reports only the configured one, so the port cannot be
//! read back from the server. These helpers ask the kernel for a free port
//! instead: bind port 0, read the port it chose, release it, and pass it on.
//! Another process can take the port in between, but only by drawing the
//! same one from the ephemeral range in that window, where two runs with a
//! constant collide every time.
//!
//! QUIC listens on UDP and gRPC, metrics and LSP on TCP: probe the protocol
//! the listener will use (`freeUdpPort` for `--listen`, `freeTcpPort` for
//! `--listen-grpc` or GEODE_METRICS_PORT).
//!
//! `udpPortHeld` is the reverse probe: whether something still holds a UDP
//! port. A QUIC client uses it as a liveness signal for the server it talks
//! to (proto_test_util `QuicProtoClient`): the kernel releases a process's
//! ports when it exits, so a port nobody holds means the server is gone.
//! Depends on std only, so any test file can import it.
const std = @import("std");

fn withIo(comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    return @call(.auto, f, .{threaded.io()} ++ args);
}

/// A UDP port no socket is bound to on any local address at this instant.
pub fn freeUdpPort() !u16 {
    return withIo(freeUdpPortIo, .{});
}

fn freeUdpPortIo(io: std.Io) !u16 {
    // The wildcard address: a port free there is free on every address.
    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", 0);
    const socket = try addr.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer socket.close(io);
    return socket.address.getPort();
}

/// A TCP port nothing listens on, on any local address, at this instant.
pub fn freeTcpPort() !u16 {
    return withIo(freeTcpPortIo, .{});
}

fn freeTcpPortIo(io: std.Io) !u16 {
    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    return server.socket.address.getPort();
}

/// A UDP port distinct from every port in `taken` (for a server that needs
/// several listeners, or a test that starts several servers at once).
pub fn freeUdpPortExcept(taken: []const u16) !u16 {
    var attempts: usize = 0;
    while (attempts < 64) : (attempts += 1) {
        const port = try freeUdpPort();
        if (std.mem.indexOfScalar(u16, taken, port) == null) return port;
    }
    return error.NoFreePort;
}

/// A TCP port distinct from every port in `taken`.
pub fn freeTcpPortExcept(taken: []const u16) !u16 {
    var attempts: usize = 0;
    while (attempts < 64) : (attempts += 1) {
        const port = try freeTcpPort();
        if (std.mem.indexOfScalar(u16, taken, port) == null) return port;
    }
    return error.NoFreePort;
}

pub const Held = enum { held, free, unknown };

/// Whether a socket is bound to UDP `address` (an IP literal of this host):
/// a bind without SO_REUSEADDR/SO_REUSEPORT fails with AddressInUse while
/// any other socket holds it. `unknown` when the probe itself failed (the
/// address is not local, descriptors exhausted), which callers must not read
/// as "gone".
pub fn udpPortHeld(address: std.Io.net.IpAddress) Held {
    return withIo(udpPortHeldIo, .{address});
}

fn udpPortHeldIo(io: std.Io, address: std.Io.net.IpAddress) Held {
    const socket = address.bind(io, .{ .mode = .dgram, .protocol = .udp }) catch |err| return switch (err) {
        error.AddressInUse => .held,
        else => .unknown,
    };
    socket.close(io);
    return .free;
}

/// True for 127.0.0.0/8 and ::1, the addresses a test server listens on and
/// the only ones `udpPortHeld` is used for.
pub fn isLoopback(address: std.Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |a| a.bytes[0] == 127,
        .ip6 => |a| std.mem.eql(u8, &a.bytes, &(.{0} ** 15 ++ .{1})),
    };
}
