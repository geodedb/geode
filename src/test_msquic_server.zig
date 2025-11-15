const std = @import("std");
const msquic = @import("transport/msquic_wrapper.zig");
const quic_msquic = @import("transport/quic_msquic.zig");

test "msquic server listen" {
    const allocator = std.testing.allocator;
    
    const config = quic_msquic.QuicTransport.Config{
        .address = "0.0.0.0",
        .port = 17567, // Use different port for testing
        .cert_path = "test_certs/server.crt",
        .key_path = "test_certs/server.key",
    };
    
    var transport = try quic_msquic.QuicTransport.init(allocator, config);
    defer transport.deinit();
    
    try transport.listen();
    
    std.debug.print("✅ Server listening on port 17567\n", .{});
}

test "msquic client connection" {
    const allocator = std.testing.allocator;
    
    var client = quic_msquic.QuicClient.init(allocator);
    defer client.deinit();
    
    // Just test initialization, actual connection needs running server
    try client.connectInsecure("127.0.0.1", 17567, true);
    
    std.debug.print("✅ Client initialized\n", .{});
}
