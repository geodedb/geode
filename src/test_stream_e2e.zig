const std = @import("std");
const QuicTransport = @import("transport/quic_msquic.zig").QuicTransport;
const QuicClient = @import("transport/quic_msquic.zig").QuicClient;

test "Phase 8: Bidirectional stream data transfer" {
    const allocator = std.testing.allocator;

    // Start server in a thread
    const ServerThread = struct {
        transport: *QuicTransport,

        fn run(self: *@This()) !void {
            std.debug.print("\n[SERVER] Waiting for connection...\n", .{});
            const conn = try self.transport.accept();
            std.debug.print("[SERVER] Connection accepted\n", .{});

            // Wait a bit for client to open stream
            std.Thread.sleep(100 * std.time.ns_per_ms);

            std.debug.print("[SERVER] Waiting for stream...\n", .{});
            const stream = try conn.acceptStream();
            std.debug.print("[SERVER] Stream accepted\n", .{});

            // Read data from client
            var read_buf: [1024]u8 = undefined;
            var total_read: usize = 0;

            // Try reading for up to 2 seconds
            var attempts: usize = 0;
            while (attempts < 200) : (attempts += 1) {
                const n = try stream.read(read_buf[total_read..]);
                if (n > 0) {
                    total_read += n;
                    std.debug.print("[SERVER] Read {} bytes (total: {})\n", .{ n, total_read });

                    // Check if we got the complete message
                    if (total_read >= 12) { // "Hello QUIC!\n"
                        break;
                    }
                }
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }

            const received = read_buf[0..total_read];
            std.debug.print("[SERVER] Received: '{s}'\n", .{received});

            // Echo back to client
            try stream.writeAll("Echo: ");
            try stream.writeAll(received);
            std.debug.print("[SERVER] Echoed response\n", .{});

            // Wait a bit for client to receive
            std.Thread.sleep(200 * std.time.ns_per_ms);

            // Close stream
            stream.close();
            allocator.destroy(stream);

            // Close connection
            conn.close();
            allocator.destroy(conn);

            std.debug.print("[SERVER] Cleanup complete\n", .{});
        }
    };

    // Initialize server
    var transport = try QuicTransport.init(allocator, .{
        .address = "127.0.0.1",
        .port = 18568,
        .cert_path = "data_test_msquic/server.crt",
        .key_path = "data_test_msquic/server.key",
    });
    defer transport.deinit();

    // Create data dir
    std.fs.cwd().makeDir("data_test_msquic") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    try transport.listen();
    std.debug.print("✅ E2E: Server listening on port 18568\n", .{});

    // Start server thread
    var server_ctx = ServerThread{ .transport = &transport };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{&server_ctx});

    // Give server time to start accepting
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Client connects
    std.debug.print("\n[CLIENT] Connecting to server...\n", .{});
    var client = QuicClient.init(allocator);
    defer client.deinit();

    try client.connectInsecure("127.0.0.1", 18568, true); // skip_verify = true
    std.debug.print("[CLIENT] Connected\n", .{});

    // Wait for handshake to complete
    std.Thread.sleep(200 * std.time.ns_per_ms);

    // Open a bidirectional stream
    std.debug.print("[CLIENT] Opening stream...\n", .{});
    const stream = try client.openStream();
    std.debug.print("[CLIENT] Stream opened\n", .{});

    // Send data
    const message = "Hello QUIC!\n";
    try stream.writeAll(message);
    std.debug.print("[CLIENT] Sent: '{s}'\n", .{message});

    // Wait for server to process and echo
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // Read echo response
    var response_buf: [1024]u8 = undefined;
    var total_received: usize = 0;

    // Try reading for up to 2 seconds
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        const n = try stream.read(response_buf[total_received..]);
        if (n > 0) {
            total_received += n;
            std.debug.print("[CLIENT] Received {} bytes (total: {})\n", .{ n, total_received });

            // Check if we got the complete echo
            const expected_len = 6 + message.len; // "Echo: " + message
            if (total_received >= expected_len) {
                break;
            }
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    const response = response_buf[0..total_received];
    std.debug.print("[CLIENT] Full response: '{s}'\n", .{response});

    // Verify echo
    const expected = "Echo: Hello QUIC!\n";
    if (std.mem.eql(u8, response, expected)) {
        std.debug.print("✅ E2E: Bidirectional stream data transfer successful!\n", .{});
    } else {
        std.debug.print("❌ E2E: Response mismatch\n", .{});
        std.debug.print("  Expected: '{s}'\n", .{expected});
        std.debug.print("  Got: '{s}'\n", .{response});
        return error.ResponseMismatch;
    }

    // Wait for server thread
    server_thread.join();

    std.debug.print("✅ E2E: Test complete\n", .{});
}

test "Phase 8: Multiple streams on same connection" {
    const allocator = std.testing.allocator;

    // Start server
    const ServerThread = struct {
        transport: *QuicTransport,

        fn run(self: *@This()) !void {
            std.debug.print("\n[SERVER] Waiting for connection...\n", .{});
            const conn = try self.transport.accept();
            std.debug.print("[SERVER] Connection accepted\n", .{});

            // Accept and handle 3 streams
            var i: usize = 0;
            while (i < 3) : (i += 1) {
                std.Thread.sleep(100 * std.time.ns_per_ms);

                std.debug.print("[SERVER] Waiting for stream {}...\n", .{i});
                const stream = try conn.acceptStream();
                std.debug.print("[SERVER] Stream {} accepted\n", .{i});

                // Read data
                var buf: [256]u8 = undefined;
                var total: usize = 0;

                var attempts: usize = 0;
                while (attempts < 100) : (attempts += 1) {
                    const n = try stream.read(buf[total..]);
                    if (n > 0) {
                        total += n;
                        if (total >= 7) break; // "Stream X"
                    }
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                }

                std.debug.print("[SERVER] Stream {} received: '{s}'\n", .{ i, buf[0..total] });

                // Send response
                const response = try std.fmt.allocPrint(allocator, "ACK {}\n", .{i});
                defer allocator.free(response);
                try stream.writeAll(response);

                stream.close();
                allocator.destroy(stream);
            }

            conn.close();
            allocator.destroy(conn);
            std.debug.print("[SERVER] All streams handled\n", .{});
        }
    };

    var transport = try QuicTransport.init(allocator, .{
        .address = "127.0.0.1",
        .port = 18569,
        .cert_path = "data_test_msquic/server.crt",
        .key_path = "data_test_msquic/server.key",
    });
    defer transport.deinit();

    try transport.listen();
    std.debug.print("✅ E2E: Server listening on port 18569\n", .{});

    var server_ctx = ServerThread{ .transport = &transport };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{&server_ctx});

    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Client
    var client = QuicClient.init(allocator);
    defer client.deinit();

    try client.connectInsecure("127.0.0.1", 18569, true);
    std.debug.print("[CLIENT] Connected\n", .{});

    std.Thread.sleep(200 * std.time.ns_per_ms);

    // Open and use 3 streams
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const stream = try client.openStream();
        std.debug.print("[CLIENT] Stream {} opened\n", .{i});

        const message = try std.fmt.allocPrint(allocator, "Stream {}\n", .{i});
        defer allocator.free(message);
        try stream.writeAll(message);
        std.debug.print("[CLIENT] Sent: '{s}'\n", .{message});

        // Wait for response
        std.Thread.sleep(300 * std.time.ns_per_ms);

        var buf: [256]u8 = undefined;
        var total: usize = 0;

        var attempts: usize = 0;
        while (attempts < 100) : (attempts += 1) {
            const n = try stream.read(buf[total..]);
            if (n > 0) {
                total += n;
                if (total >= 5) break; // "ACK X\n"
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        std.debug.print("[CLIENT] Stream {} response: '{s}'\n", .{ i, buf[0..total] });
    }

    server_thread.join();

    std.debug.print("✅ E2E: Multiple streams test complete\n", .{});
}
