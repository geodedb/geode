const std = @import("std");
const cdc = @import("../src/streaming/cdc_enhanced.zig");

// TestCANARY_REQ_GQL_042_CDC_WalIngest

test "TestCANARY_REQ_GQL_042_CDC_WalIngest" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try cdc.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc.CDCSink{.memory}, .batch_size = 100 });
    defer engine.deinit();
    try engine.start();

    try engine.ingestFromWalRecord(99, .node, 7, "{\"id\":7,\"v\":1}");
    try engine.ingestFromWalRecord(100, .node, 7, "{\"id\":7,\"v\":2}");
    try engine.flushNow();

    const st = engine.getStatus();
    try std.testing.expect(st.total_events == 2);
    engine.stop();
}
