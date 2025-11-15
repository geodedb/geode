const std = @import("std");
const QuicTransport = @import("transport/quic_msquic.zig").QuicTransport;

test "Phase 8: Simple server startup" {
    const allocator = std.testing.allocator;
    
    // Initialize server
    var transport = try QuicTransport.init(allocator, .{
        .address = "127.0.0.1",
        .port = 18570,
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
    std.debug.print("✅ Phase 8: Server listening on port 18570\n", .{});
    
    // Wait a bit
    std.Thread.sleep(200 * std.time.ns_per_ms);
    
    std.debug.print("✅ Phase 8: Server startup test complete\n", .{});
}
