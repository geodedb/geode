const std = @import("std");
const msquic = @import("transport/msquic_wrapper.zig");

// Minimal test to debug ConnectionStart blocking
test "Debug ConnectionStart blocking" {
    const allocator = std.testing.allocator;

    std.debug.print("\n=== Debugging ConnectionStart ===\n", .{});

    // Init msquic
    var mq = try msquic.MsQuic.init(allocator);
    defer mq.deinit();
    std.debug.print("✅ MsQuic initialized\n", .{});

    // Create client config
    try mq.createClientConfiguration("geode/1", true);
    std.debug.print("✅ Client configuration created: {*}\n", .{mq.configuration});

    // Create connection context
    var conn_ctx = try msquic.ConnectionContext.init(allocator);
    defer conn_ctx.deinit();
    std.debug.print("✅ Connection context created\n", .{});

    // Open connection
    var conn: msquic.HQUIC = null;
    const open_status = mq.api.ConnectionOpen(
        mq.registration,
        msquic.connectionCallback,
        conn_ctx,
        &conn,
    );
    std.debug.print("ConnectionOpen status: 0x{X}\n", .{open_status});

    if (msquic.QUIC_FAILED(open_status)) {
        std.debug.print("❌ ConnectionOpen failed\n", .{});
        return error.ConnectionOpenFailed;
    }
    defer if (conn) |c| mq.api.ConnectionClose(c);

    std.debug.print("✅ Connection opened: {*}\n", .{conn});

    // For CLIENT connections: Configuration is passed to ConnectionStart, not SetConfiguration!
    std.debug.print("⏭️  Skipping ConnectionSetConfiguration (config passed to ConnectionStart instead)\n", .{});

    // Try ConnectionStart with configuration
    std.debug.print("⚠️  About to call ConnectionStart with configuration...\n", .{});

    var addr_buf: [256]u8 = undefined;
    const addr_z = try std.fmt.bufPrintZ(&addr_buf, "127.0.0.1", .{});

    // Pass configuration to ConnectionStart!
    std.debug.print("   Calling ConnectionStart(conn={*}, config={*}, family=2, addr=\"127.0.0.1\", port=18567)\n", .{ conn, mq.configuration });
    const start_status = mq.api.ConnectionStart(
        conn,
        mq.configuration, // ← NOW PASSING CONFIGURATION!
        2, // AF_INET
        addr_z.ptr,
        18567,
    );

    std.debug.print("ConnectionStart returned! status: 0x{X}\n", .{start_status});

    if (start_status == msquic.QUIC_STATUS_PENDING) {
        std.debug.print("✅ Connection is pending (async)\n", .{});
    } else if (msquic.QUIC_FAILED(start_status)) {
        std.debug.print("❌ ConnectionStart failed\n", .{});
    } else {
        std.debug.print("✅ ConnectionStart succeeded immediately\n", .{});
    }
}
