const std = @import("std");
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC"; ASPECT=AdaptiveStressHarness; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_042_CDC_AdaptiveStressHarness; OWNER=streaming; UPDATED=2025-09-21

test "BenchmarkCANARY_REQ_GQL_042_CDC_AdaptiveStressHarness" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cdc = @import("../src/streaming/cdc_enhanced.zig");

    var engine = try cdc.CDCEngine.init(allocator, .{
        .enabled = true,
        .adaptive_backpressure = true,
        .pending_backpressure_watermark = 8_000,
        .batch_size = 512,
        .flush_interval_ms = 10_000,
        .sinks = &[_]cdc.CDCSink{},
    });
    defer engine.deinit();

    // Simulate bursts of events to trigger watermark shrink/grow
    var burst: usize = 0;
    const cycles = 120;
    while (burst < cycles) : (burst += 1) {
        const size = if (burst % 3 == 0) 10_000 else 1_000; // high load every 3rd cycle
        var i: usize = 0;
        while (i < size) : (i += 1) {
            try engine.captureChange(.insert, .node, @as(u64, @intCast(i)), null, "{\"id\":1}");
        }
        // perform adaptive adjustment pass
        engine.adaptiveTick();
    }

    // Collect metrics: watermark adjustments counter vs cycles
    const final_wm = engine.config.pending_backpressure_watermark;
    const adjustments = engine.batch_adjustments; // reused counter per code comment

    // Expect some adjustments (>=2) and watermark stays within configured bounds
    try std.testing.expect(adjustments >= 2);
    try std.testing.expect(final_wm >= engine.config.backpressure_min_watermark);
    try std.testing.expect(final_wm <= engine.config.backpressure_max_watermark);
}
