const std = @import("std");
const streaming = @import("../src/streaming/cdc_enhanced.zig");

// Integrative umbrella streaming test covering backpressure + adaptive flush toggles.
// TestCANARY_REQ_GQL_042_CDC_StreamingUmbrella

test "TestCANARY_REQ_GQL_042_CDC_StreamingUmbrella" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try streaming.CDCEngine.init(allocator, .{
        .enabled = true,
        .adaptive_flush = true,
        .adaptive_backpressure = true,
        .pending_backpressure_watermark = 2_000,
        .batch_size = 256,
        .sinks = &[_]streaming.CDCSink{},
    });
    defer engine.deinit();

    try engine.start();
    try std.testing.expect(engine.isRunning());

    // Simulate load to trigger backpressure heuristics
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try engine.captureChange(.insert, .node, @as(u64, @intCast(i)), null, "{\"id\":1}");
        if (i == 25) {
            // Toggle adaptive flush and backpressure
            engine.config.adaptive_flush = false;
            engine.config.adaptive_backpressure = false;
        }
    }

    // Export diagnostics and assert invariants
    var diag1 = try engine.exportDiagnostics(allocator);
    defer diag1.deinit(allocator);
    try std.testing.expect(diag1.events_captured >= 50);

    // Re-enable adaptive diff and capture a few more events
    engine.config.adaptive_flush = true;
    engine.config.adaptive_backpressure = true;
    var j: usize = 0;
    while (j < 5) : (j += 1) {
        try engine.captureChange(.update, .node, @as(u64, 100 + @intCast(j)), null, "{\"id\":2}");
    }

    var diag2 = try engine.exportDiagnostics(allocator);
    defer diag2.deinit(allocator);
    try std.testing.expect(diag2.events_captured >= diag1.events_captured + 5);
    try engine.stop();
    try std.testing.expect(!engine.isRunning());
}
