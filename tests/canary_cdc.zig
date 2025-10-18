const std = @import("std");
const cdc = @import("../src/streaming/cdc_enhanced.zig");

// Simple start/stop smoke test for CDC engine - placeholder until real WAL tail integration.
// TestCANARY_REQ_GQL_042_CDC_StartStop

test "TestCANARY_REQ_GQL_042_CDC_StartStop" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var engine = try cdc.CDCEngine.init(allocator, .{ .enabled = false });
    defer engine.deinit();
    // Start should be a no-op when disabled
    try engine.start();
    try std.testing.expect(!engine.isRunning());
    // Enable and start
    engine.config.enabled = true;
    try engine.start();
    try std.testing.expect(engine.isRunning());
    try engine.stop();
    try std.testing.expect(!engine.isRunning());
}
