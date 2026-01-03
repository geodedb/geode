const std = @import("std");
const msquic = @import("transport/msquic_wrapper.zig");

test "Zig client opens stream to server" {
    const allocator = std.testing.allocator;

    std.debug.print("\n=== Zig Client Stream Test ===\n", .{});

    // Start server in background thread
    const ServerThread = struct {
        server: *msquic.MsQuic,

        fn run(self: *@This()) !void {
            std.debug.print("[SERVER] Thread started\n", .{});

            // Wait for connection
            var attempts: usize = 0;
            while (attempts < 100) : (attempts += 1) {
                if (self.server.listener_ctx) |ctx| {
                    ctx.mutex.lock();
                    const has_conn = ctx.pending_connections.items.len > 0;
                    ctx.mutex.unlock();

                    if (has_conn) {
                        std.debug.print("[SERVER] Connection available!\n", .{});
                        break;
                    }
                }
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }

            std.debug.print("[SERVER] Checking for streams...\n", .{});
            // Wait a bit for stream to be opened
            std.Thread.sleep(1000 * std.time.ns_per_ms);

            std.debug.print("[SERVER] Thread complete\n", .{});
        }
    };

    // Create server
    var server = try msquic.MsQuic.init(allocator);
    defer server.deinit();
    std.debug.print("✅ Server initialized\n", .{});

    // Create server configuration
    try server.createServerConfiguration(
        "certs/server.crt",
        "certs/server.key",
        "geode/1",
    );
    std.debug.print("✅ Server configuration created\n", .{});

    // Start listener
    try server.startListener("127.0.0.1", 18999, "geode/1");
    std.debug.print("✅ Server listening on port 18999\n", .{});

    // Start server thread
    var server_thread_ctx = ServerThread{ .server = &server };
    const server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{&server_thread_ctx});

    // Give server time to start
    std.Thread.sleep(200 * std.time.ns_per_ms);

    // Create client
    var client = try msquic.MsQuic.init(allocator);
    defer client.deinit();
    std.debug.print("✅ Client initialized\n", .{});

    // Create client configuration (insecure)
    try client.createClientConfiguration("geode/1", true);
    std.debug.print("✅ Client configuration created\n", .{});

    // Create connection context
    var conn_ctx = try msquic.ConnectionContext.init(allocator);
    defer conn_ctx.deinit();

    // Open connection
    var connection: msquic.HQUIC = undefined;
    const open_status = client.api.ConnectionOpen(
        client.registration,
        msquic.connectionCallback,
        conn_ctx,
        &connection,
    );

    if (open_status != msquic.QUIC_STATUS_SUCCESS) {
        std.debug.print("❌ ConnectionOpen failed: 0x{X}\n", .{open_status});
        return error.TestFailed;
    }
    std.debug.print("✅ Connection opened\n", .{});

    // Start connection
    var addr_buf: [20]u8 = undefined;
    const addr_z = try std.fmt.bufPrintZ(&addr_buf, "127.0.0.1", .{});

    const start_status = client.api.ConnectionStart(
        connection,
        client.configuration,
        2, // AF_INET
        addr_z.ptr,
        18999,
    );

    std.debug.print("ConnectionStart status: 0x{X}\n", .{start_status});

    // Wait for connection
    std.Thread.sleep(500 * std.time.ns_per_ms);

    conn_ctx.mutex.lock();
    const connected = conn_ctx.connected;
    conn_ctx.mutex.unlock();

    if (!connected) {
        std.debug.print("❌ Connection failed\n", .{});
        client.api.ConnectionClose(connection);
        server_thread.join();
        return error.TestFailed;
    }

    std.debug.print("✅ Connection established!\n", .{});

    // Now open a stream
    std.debug.print("Opening bidirectional stream...\n", .{});

    var stream_ctx = try msquic.StreamContext.init(allocator);
    defer stream_ctx.deinit();

    var stream_handle: msquic.HQUIC = undefined;
    const stream_open_status = client.api.StreamOpen(
        connection,
        0, // Bidirectional
        msquic.streamCallback,
        stream_ctx,
        &stream_handle,
    );

    if (stream_open_status != msquic.QUIC_STATUS_SUCCESS) {
        std.debug.print("❌ StreamOpen failed: 0x{X}\n", .{stream_open_status});
        client.api.ConnectionClose(connection);
        server_thread.join();
        return error.TestFailed;
    }

    std.debug.print("✅ Stream opened\n", .{});

    // Start stream
    const stream_start_status = client.api.StreamStart(
        stream_handle,
        1, // IMMEDIATE
    );

    if (stream_start_status != msquic.QUIC_STATUS_SUCCESS and stream_start_status != msquic.QUIC_STATUS_PENDING) {
        std.debug.print("❌ StreamStart failed: 0x{X}\n", .{stream_start_status});
        client.api.StreamClose(stream_handle);
        client.api.ConnectionClose(connection);
        server_thread.join();
        return error.TestFailed;
    }

    std.debug.print("✅ Stream started (status: 0x{X})\n", .{stream_start_status});

    // Send some data
    const hello = "HELLO FROM ZIG CLIENT\n";
    var buffer = msquic.QUIC_BUFFER{
        .Length = @intCast(hello.len),
        .Buffer = @constCast(hello.ptr),
    };

    const send_status = client.api.StreamSend(
        stream_handle,
        @ptrCast(&buffer),
        1,
        0, // flags
        null,
    );

    std.debug.print("StreamSend status: 0x{X}\n", .{send_status});

    // Wait for server to process
    std.Thread.sleep(1000 * std.time.ns_per_ms);

    // Check if server received PEER_STREAM_STARTED
    if (server.listener_ctx) |ctx| {
        ctx.mutex.lock();
        if (ctx.pending_connections.items.len > 0) {
            const pending = ctx.pending_connections.items[0];
            pending.context.mutex.lock();
            const stream_count = pending.context.pending_streams.items.len;
            pending.context.mutex.unlock();

            std.debug.print("[CHECK] Server has {} pending stream(s)\n", .{stream_count});

            if (stream_count > 0) {
                std.debug.print("✅ Server received PEER_STREAM_STARTED!\n", .{});
            } else {
                std.debug.print("❌ Server did NOT receive PEER_STREAM_STARTED\n", .{});
            }
        }
        ctx.mutex.unlock();
    }

    // Cleanup
    client.api.StreamClose(stream_handle);
    client.api.ConnectionClose(connection);
    server_thread.join();

    std.debug.print("✅ Test complete\n", .{});
}
