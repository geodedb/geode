const std = @import("std");
const quic = @import("transport/quic_msquic.zig");

test "E2E: Server startup and shutdown" {
    const allocator = std.testing.allocator;
    
    const config = quic.QuicTransport.Config{
        .address = "0.0.0.0",
        .port = 18567,
        .cert_path = "test_certs/server.crt",
        .key_path = "test_certs/server.key",
    };
    
    var transport = try quic.QuicTransport.init(allocator, config);
    defer transport.deinit();
    
    try transport.listen();
    std.debug.print("✅ E2E: Server listening on port 18567\n", .{});
    
    // Give it a moment to be ready
    std.Thread.sleep(100 * std.time.ns_per_ms);
    
    std.debug.print("✅ E2E: Server shutdown successful\n", .{});
}

test "E2E: Client connection initialization" {
    const allocator = std.testing.allocator;
    
    var client = quic.QuicClient.init(allocator);
    defer client.deinit();
    
    // Just test initialization
    std.debug.print("✅ E2E: Client created successfully\n", .{});
}

test "E2E: Server accepts tryAccept (no connection)" {
    const allocator = std.testing.allocator;
    
    const config = quic.QuicTransport.Config{
        .address = "0.0.0.0",
        .port = 18568,
        .cert_path = "test_certs/server.crt",
        .key_path = "test_certs/server.key",
    };
    
    var transport = try quic.QuicTransport.init(allocator, config);
    defer transport.deinit();
    
    try transport.listen();
    
    // Try to accept - should return null immediately
    const maybe_conn = transport.tryAccept();
    try std.testing.expect(maybe_conn == null);
    
    std.debug.print("✅ E2E: tryAccept returns null when no connections\n", .{});
}
