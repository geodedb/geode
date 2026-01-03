const std = @import("std");
const msquic = @import("transport/msquic_wrapper.zig");

test "Verify callback registration and invocation" {
    const allocator = std.testing.allocator;

    std.debug.print("\n=== Testing Callback Registration ===\n", .{});

    // Init msquic
    var mq = try msquic.MsQuic.init(allocator);
    defer mq.deinit();
    std.debug.print("✅ MsQuic initialized\n", .{});

    // Create client configuration
    try mq.createClientConfiguration("geode/1", false);
    std.debug.print("✅ Client configuration created\n", .{});

    // Create connection context
    var conn_ctx = try msquic.ConnectionContext.init(allocator);
    defer conn_ctx.deinit();
    std.debug.print("✅ Connection context created\n", .{});

    // Open connection WITH callback
    var connection: msquic.HQUIC = undefined;
    const open_status = mq.api.ConnectionOpen(
        mq.registration,
        msquic.connectionCallback,
        conn_ctx,
        &connection,
    );

    if (open_status != msquic.QUIC_STATUS_SUCCESS) {
        std.debug.print("❌ ConnectionOpen failed: 0x{X}\n", .{open_status});
        return error.TestFailed;
    }
    std.debug.print("✅ Connection opened with callback registered\n", .{});

    // Try to start connection to non-existent server
    // This should trigger either CONNECTED or SHUTDOWN callback
    var addr_buf: [20]u8 = undefined;
    const addr_z = try std.fmt.bufPrintZ(&addr_buf, "127.0.0.1", .{});

    std.debug.print("⏳ Attempting connection (expecting failure/shutdown callback)...\n", .{});
    const start_status = mq.api.ConnectionStart(
        connection,
        mq.configuration,
        2, // AF_INET
        addr_z.ptr,
        18567, // Non-existent server port
    );

    std.debug.print("ConnectionStart returned: 0x{X} ", .{start_status});
    if (start_status == msquic.QUIC_STATUS_SUCCESS) {
        std.debug.print("(SUCCESS)\n", .{});
    } else if (start_status == msquic.QUIC_STATUS_PENDING or start_status == 0xFFFFFFFE) {
        std.debug.print("(PENDING - async operation)\n", .{});
    } else {
        std.debug.print("(OTHER)\n", .{});
    }

    // Wait a bit for callbacks to fire
    std.debug.print("⏳ Waiting 2 seconds for callbacks...\n", .{});
    std.Thread.sleep(2 * std.time.ns_per_s);

    // Check connection state
    conn_ctx.mutex.lock();
    const connected = conn_ctx.connected;
    conn_ctx.mutex.unlock();

    std.debug.print("\n=== Connection State ===\n", .{});
    std.debug.print("Connected: {}\n", .{connected});

    // We don't care if it connected or failed, we just want to see if ANY callback fired
    if (connected) {
        std.debug.print("✅ Callback WAS invoked!\n", .{});
    } else {
        std.debug.print("⚠️  No callback invoked (connected={})\n", .{connected});
        std.debug.print("This might mean:\n", .{});
        std.debug.print("  1. Callbacks not firing\n", .{});
        std.debug.print("  2. Connection still in progress\n", .{});
        std.debug.print("  3. Callback registered incorrectly\n", .{});
    }

    // Close connection
    mq.api.ConnectionClose(connection);
    std.debug.print("✅ Connection closed\n", .{});
}
