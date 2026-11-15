// SONNY-6607 (5): the gRPC client's negotiated max frame size belongs to the
// connection that negotiated it, not to the thread.
//
// `grpc_query_transport` kept the peer's SETTINGS_MAX_FRAME_SIZE in a
// thread-local, so two connections used from one thread shared it: after a
// second connection learned a larger size, a request on the first was sent
// in frames its peer never allowed (a FRAME_SIZE_ERROR, RFC 9113 4.2).
//
// The real client functions over two socket pairs, the far end of each
// playing the peer: B's peer advertises SETTINGS_MAX_FRAME_SIZE = 65536
// (`drainInitialSettings` reads it), A's never advertises one. A 40,000-byte
// request on A must arrive in DATA frames of at most the default 16384.
//
// CANARY: REQ=REQ-SONNY-6607-GRPC-FRAME-SIZE; FEATURE="GrpcTransport"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6607_grpc_frame_size.zig; OWNER=transport; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const gq = geode.grpc_query_transport;

const linux = std.os.linux;

fn streamOf(fd: i32) std.Io.net.Stream {
    return .{ .socket = .{ .handle = fd, .address = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable } };
}

fn pair() ![2]i32 {
    var fds: [2]i32 = undefined;
    if (linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    return fds;
}

fn writeRaw(fd: i32, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        if (@as(isize, @bitCast(n)) <= 0) return error.WriteFailed;
        off += n;
    }
}

fn readExact(fd: i32, dest: []u8) !void {
    var off: usize = 0;
    while (off < dest.len) {
        const n = linux.read(fd, dest[off..].ptr, dest.len - off);
        if (@as(isize, @bitCast(n)) <= 0) return error.ReadFailed;
        off += n;
    }
}

fn frameHeader(len: u24, ftype: u8, flags: u8, sid: u31) [9]u8 {
    return .{ @intCast(len >> 16), @intCast((len >> 8) & 0xff), @intCast(len & 0xff), ftype, flags, @intCast(sid >> 24), @intCast((sid >> 16) & 0xff), @intCast((sid >> 8) & 0xff), @intCast(sid & 0xff) };
}

test "SONNY-6607 (5): a connection's max frame size is its own, not the thread's" {
    const a = try pair();
    defer for (a) |fd| {
        _ = linux.close(fd);
    };
    const b = try pair();
    defer for (b) |fd| {
        _ = linux.close(fd);
    };

    // B's peer: SETTINGS { MAX_FRAME_SIZE (0x5) = 65536 }, then an ACK of the
    // client's settings, so `drainInitialSettings` returns.
    const settings_payload = [_]u8{ 0x00, 0x05, 0x00, 0x01, 0x00, 0x00 };
    try writeRaw(b[1], &frameHeader(6, 0x4, 0, 0));
    try writeRaw(b[1], &settings_payload);
    try writeRaw(b[1], &frameHeader(0, 0x4, 0x1, 0));
    try gq.drainInitialSettings(testing.allocator, streamOf(b[0]), .{});

    // A 40,000-byte request on A, whose peer advertised nothing.
    const msg = try testing.allocator.alloc(u8, 40_000);
    defer testing.allocator.free(msg);
    @memset(msg, 'x');
    try gq.sendRequest(testing.allocator, streamOf(a[0]), "/geode.GeodeService/Execute", msg, 1);

    // A's peer reads every frame up to END_STREAM DATA.
    var largest: usize = 0;
    var data_bytes: usize = 0;
    const payload_buf = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(payload_buf);
    while (true) {
        var h: [9]u8 = undefined;
        try readExact(a[1], &h);
        const len: usize = (@as(usize, h[0]) << 16) | (@as(usize, h[1]) << 8) | h[2];
        try readExact(a[1], payload_buf[0..len]);
        if (h[3] != 0x0) continue; // not DATA
        largest = @max(largest, len);
        data_bytes += len;
        if ((h[4] & 0x1) != 0) break;
    }
    std.debug.print("SONNY-6607 (5) request on the connection that negotiated nothing: {d} bytes, largest DATA frame {d}\n", .{ data_bytes, largest });
    try testing.expectEqual(msg.len + 5, data_bytes);
    try testing.expect(largest <= 16384);
}
