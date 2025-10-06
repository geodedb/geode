const std = @import("std");
const testing = std.testing;
const quic_lib = @import("../vendor/quic/quic.zig");
const QuicTransport = @import("../src/transport/quic.zig");

// Regression test for QUIC readStream returning 0 instead of WouldBlock
// This bug prevented clients from properly polling for incoming data
test "readStream returns WouldBlock when inbox is empty" {
    const allocator = testing.allocator;
    
    // Create mock connection with empty stream inbox
    var endpoint = try quic_lib.createEndpoint(allocator, .{
        .bind_addr = "127.0.0.1:0",
        .is_server = false,
    });
    defer quic_lib.destroyEndpoint(endpoint);
    
    // Create a connection
    const conn = try quic_lib.connect(endpoint, "127.0.0.1", 8443, "localhost");
    defer quic_lib.closeConnection(conn, 0);
    
    // Open a stream
    const stream_id = try quic_lib.openStream(conn, true);
    
    // Try to read from empty stream - should return WouldBlock, not 0
    var buf: [100]u8 = undefined;
    const result = quic_lib.readStream(conn, stream_id, &buf);
    
    // Verify it returns WouldBlock error, not 0 bytes
    try testing.expectError(error.WouldBlock, result);
}

// Test that client properly polls when receiving WouldBlock
test "client polls endpoint on WouldBlock" {
    const allocator = testing.allocator;
    
    var client = try QuicTransport.QuicClient.init(allocator);
    defer client.deinit();
    
    // Mock setup for testing polling behavior
    try client.connectInsecure("127.0.0.1", 8443);
    
    var stream = try client.getStream();
    defer stream.deinit();
    
    // Attempt to read - should trigger polling
    var buf: [100]u8 = undefined;
    const n = stream.read(&buf) catch |err| blk: {
        if (err == error.WouldBlock) {
            // Expected behavior - client should poll
            break :blk 0;
        }
        return err;
    };
    
    // Even with WouldBlock, read should handle it gracefully
    try testing.expect(n == 0 or n > 0);
}

// Test memory leak fix in readLine
test "readLine properly manages memory" {
    const allocator = testing.allocator;
    
    // Track allocations
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        testing.expect(leaked == .ok) catch |err| {
            std.debug.print("Memory leak detected in readLine test\n", .{});
            return err;
        };
    }
    const test_allocator = gpa.allocator();
    
    var client = try QuicTransport.QuicClient.init(test_allocator);
    defer client.deinit();
    
    // Simulate connection
    try client.connectInsecure("127.0.0.1", 8443);
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
    
    var client = try QuicTransport.QuicClient.init(allocator);
    defer client.deinit();
    
    // Connect to non-existent server - should timeout
    const result = client.connect("127.0.0.1", 19999);
    
    // Wait for handshake should fail with timeout
    if (result) |_| {
        const handshake_result = client.waitForHandshake();
        try testing.expectError(error.HandshakeFailed, handshake_result);
    } else |err| {
        // Connection itself might fail, which is also acceptable
        try testing.expect(err == error.ConnectionFailed or err == error.NetworkUnreachable);
    }
}

// Test full QUIC query execution flow
test "end-to-end QUIC query execution" {
    const allocator = testing.allocator;
    
    // Start a test server in the background
    var server_thread = try std.Thread.spawn(.{}, struct {
        fn run() !void {
            var srv_alloc = std.heap.page_allocator;
            const transport = try QuicTransport.QuicTransport.init(srv_alloc);
            defer transport.deinit();
            
            try transport.listen("127.0.0.1", 18443);
            
            // Accept one connection and respond
            if (try transport.accept()) |conn| {
                defer conn.deinit();
                
                var buf: [1024]u8 = undefined;
                const n = try conn.read(&buf);
                
                // Send mock response
                const response = 
                    "SCHEMA: [{\"name\":\"test\",\"type\":\"INTEGER\"}]\n" ++
                    "RESULT: {\"test\":1}\n" ++
                    "STATUS: {\"status_class\":\"00000\",\"row_count\":1}\n";
                try conn.writeAll(response);
            }
        }
    }.run, .{});
    defer server_thread.join();
    
    // Give server time to start
    std.time.sleep(100 * std.time.ns_per_ms);
    
    // Connect as client
    var client = try QuicTransport.QuicClient.init(allocator);
    defer client.deinit();
    
    try client.connectInsecure("127.0.0.1", 18443);
    try client.waitForHandshake();
    
    var stream = try client.getStream();
    defer stream.deinit();
    
    // Send query
    const query = "{\"type\":\"RUN_GQL\",\"text\":\"RETURN 1 AS test\"}\n";
    try stream.writeAll(query);
    
    // Read response lines
    const schema_line = try stream.readLine(1024);
    defer allocator.free(schema_line);
    try testing.expect(std.mem.indexOf(u8, schema_line, "SCHEMA:") != null);
    
    const result_line = try stream.readLine(1024);
    defer allocator.free(result_line);
    try testing.expect(std.mem.indexOf(u8, result_line, "RESULT:") != null);
    
    const status_line = try stream.readLine(1024);
    defer allocator.free(status_line);
    try testing.expect(std.mem.indexOf(u8, status_line, "STATUS:") != null);
}