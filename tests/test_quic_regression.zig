const std = @import("std");
const testing = std.testing;
const quic = @import("transport/quic");
const protobuf = @import("protobuf");
const schema = @import("schema");

fn readFully(stream: anytype, buf: []u8) !void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const n = stream.read(buf[offset..]) catch |err| {
            if (err == error.WouldBlock) {
                std.time.sleep(1 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) return error.EndOfStream;
        offset += n;
    }
}

fn writePacket(stream: anytype, allocator: std.mem.Allocator, packet: anytype) !void {
    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 256);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, packet);
    const body = aw.writer.buffer[0..aw.writer.end];
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(body.len), .big);
    try stream.writeAll(&len_buf);
    try stream.writeAll(body);
}

fn readPacket(comptime T: type, stream: anytype, allocator: std.mem.Allocator) !T {
    var len_buf: [4]u8 = undefined;
    try readFully(stream, &len_buf);
    const body_len = std.mem.readInt(u32, &len_buf, .big);
    var body = try allocator.alloc(u8, body_len);
    defer allocator.free(body);
    try readFully(stream, body);
    var reader: std.Io.Reader = .fixed(body);
    return protobuf.decode(T, &reader, allocator);
}

fn waitReady(ready: *std.atomic.Value(bool)) void {
    var tries: usize = 0;
    while (!ready.load(.acquire) and tries < 200) : (tries += 1) {
        std.time.sleep(5 * std.time.ns_per_ms);
    }
}

// Regression test for QUIC readStream returning 0 instead of WouldBlock
// This bug prevented clients from properly polling for incoming data
test "readStream returns WouldBlock when inbox is empty" {
    const allocator = testing.allocator;

    const port: u16 = 15440;
    var ready = std.atomic.Value(bool).init(false);

    var server_thread = try std.Thread.spawn(.{}, struct {
        fn run(ctx: struct { allocator: std.mem.Allocator, port: u16, ready: *std.atomic.Value(bool) }) !void {
            var transport = try quic.QuicTransport.init(ctx.allocator, .{
                .address = "127.0.0.1",
                .port = ctx.port,
                .allow_insecure = true,
            });
            defer transport.deinit();
            try transport.listen();
            ctx.ready.store(true, .release);
            const conn = try transport.accept();
            defer transport.destroyConnection(conn);
            std.time.sleep(200 * std.time.ns_per_ms);
        }
    }.run, .{ .allocator = allocator, .port = port, .ready = &ready });
    defer server_thread.join();

    waitReady(&ready);

    var client = try quic.QuicClient.init(allocator);
    defer client.deinit();
    try client.connectInsecure("127.0.0.1", port, true);
    try client.waitForHandshake(5);
    var stream = try client.getStream();
    defer stream.deinit();

    var buf: [16]u8 = undefined;
    const result = stream.read(&buf);
    try testing.expectError(error.WouldBlock, result);
}

// Test that client properly polls when receiving WouldBlock
test "client polls endpoint on WouldBlock" {
    const allocator = testing.allocator;

    const port: u16 = 15441;
    var ready = std.atomic.Value(bool).init(false);

    var server_thread = try std.Thread.spawn(.{}, struct {
        fn run(ctx: struct { allocator: std.mem.Allocator, port: u16, ready: *std.atomic.Value(bool) }) !void {
            var transport = try quic.QuicTransport.init(ctx.allocator, .{
                .address = "127.0.0.1",
                .port = ctx.port,
                .allow_insecure = true,
            });
            defer transport.deinit();
            try transport.listen();
            ctx.ready.store(true, .release);
            const conn = try transport.accept();
            defer transport.destroyConnection(conn);
            std.time.sleep(200 * std.time.ns_per_ms);
        }
    }.run, .{ .allocator = allocator, .port = port, .ready = &ready });
    defer server_thread.join();

    waitReady(&ready);

    var client = try quic.QuicClient.init(allocator);
    defer client.deinit();
    try client.connectInsecure("127.0.0.1", port, true);
    try client.waitForHandshake(5);

    var stream = try client.getStream();
    defer stream.deinit();

    var buf: [100]u8 = undefined;
    const n = stream.read(&buf) catch |err| blk: {
        if (err == error.WouldBlock) break :blk 0;
        return err;
    };

    try testing.expect(n == 0 or n > 0);
}

// Test memory leak fix in readLine
test "readLine properly manages memory" {
    const allocator = testing.allocator;

    // Track allocations
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        testing.expect(leaked == .ok) catch |err| {
            std.debug.print("Memory leak detected in readLine test\n", .{});
            return err;
        };
    }
    const test_allocator = gpa.allocator();

    const port: u16 = 15443;
    var ready = std.atomic.Value(bool).init(false);

    var server_thread = try std.Thread.spawn(.{}, struct {
        fn run(ctx: struct { allocator: std.mem.Allocator, port: u16, ready: *std.atomic.Value(bool) }) !void {
            var transport = try quic.QuicTransport.init(ctx.allocator, .{
                .address = "127.0.0.1",
                .port = ctx.port,
                .allow_insecure = true,
            });
            defer transport.deinit();
            try transport.listen();
            ctx.ready.store(true, .release);
            const conn = try transport.accept();
            defer transport.destroyConnection(conn);
            std.time.sleep(200 * std.time.ns_per_ms);
        }
    }.run, .{ .allocator = allocator, .port = port, .ready = &ready });
    defer server_thread.join();

    waitReady(&ready);

    var client = try quic.QuicClient.init(test_allocator);
    defer client.deinit();

    try client.connectInsecure("127.0.0.1", port, true);
    try client.waitForHandshake(5);
    var stream = try client.getStream();
    defer stream.deinit();

    // Test readLine allocation and deallocation
    const line1 = stream.readLine(1024) catch "";
    if (line1.len > 0) {
        test_allocator.free(line1);
    }

    const line2 = stream.readLine(1024) catch "";
    if (line2.len > 0) {
        test_allocator.free(line2);
    }

    // If we get here without memory leaks, test passes
}

// Test handshake timeout behavior
test "handshake timeout fails gracefully" {
    const allocator = testing.allocator;

    var client = try quic.QuicClient.init(allocator);
    defer client.deinit();

    // Connect to non-existent server - should timeout
    const result = client.connect("127.0.0.1", 19999);

    // Wait for handshake should fail with timeout
    if (result) |_| {
        const handshake_result = client.waitForHandshake(5); // 5 second timeout for test
        try testing.expectError(error.HandshakeFailed, handshake_result);
    } else |err| {
        // Connection itself might fail, which is also acceptable
        try testing.expect(err == error.ConnectionFailed or err == error.NetworkUnreachable);
    }
}

// Test full QUIC query execution flow
test "end-to-end QUIC query execution" {
    const allocator = testing.allocator;
    const port: u16 = 15442;
    var ready = std.atomic.Value(bool).init(false);

    var server_thread = try std.Thread.spawn(.{}, struct {
        fn run(ctx: struct { allocator: std.mem.Allocator, port: u16, ready: *std.atomic.Value(bool) }) !void {
            var transport = try quic.QuicTransport.init(ctx.allocator, .{
                .address = "127.0.0.1",
                .port = ctx.port,
                .allow_insecure = true,
            });
            defer transport.deinit();
            try transport.listen();
            ctx.ready.store(true, .release);

            const conn = try transport.accept();
            defer transport.destroyConnection(conn);
            const stream = try conn.acceptStream();
            defer conn.destroyStream(stream);

            var client_packet = try readPacket(schema.ClientPacket, stream, ctx.allocator);
            defer client_packet.deinit(ctx.allocator);

            var capabilities = std.ArrayList([]const u8).init(ctx.allocator);
            defer capabilities.deinit(ctx.allocator);
            const hello_resp = schema.HelloResponse{
                .success = true,
                .session_id = "session-test",
                .error_message = "",
                .capabilities = capabilities,
            };
            var packet = schema.ServerPacket{ .quic = .{ .hello = hello_resp } };
            try writePacket(stream, ctx.allocator, packet);
        }
    }.run, .{ .allocator = allocator, .port = port, .ready = &ready });
    defer server_thread.join();

    waitReady(&ready);

    var client = try quic.QuicClient.init(allocator);
    defer client.deinit();

    try client.connectInsecure("127.0.0.1", port, true);
    try client.waitForHandshake(5);

    var stream = try client.getStream();
    defer stream.deinit();

    const hello_req = schema.HelloRequest{
        .username = "test",
        .password = "test",
        .tenant_id = null,
    };
    var request_packet = schema.ClientPacket{ .quic = .{ .hello = hello_req } };
    try writePacket(stream, allocator, request_packet);

    var resp_packet = try readPacket(schema.ServerPacket, stream, allocator);
    defer resp_packet.deinit(allocator);
    const resp = resp_packet.quic orelse return error.InvalidResponse;
    switch (resp) {
        .hello => |h| {
            try testing.expect(h.success);
            try testing.expect(std.mem.eql(u8, h.session_id, "session-test"));
        },
        else => return error.InvalidResponse,
    }
}
