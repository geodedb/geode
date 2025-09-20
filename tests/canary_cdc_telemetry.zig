const std = @import("std");
const cdc = @import("../src/streaming/cdc_enhanced.zig");

// TestCANARY_REQ_GQL_042_CDC_Telemetry
// Verifies peak buffer and batch adjustment counters increment.

test "TestCANARY_REQ_GQL_042_CDC_Telemetry" {
    const ally = std.testing.allocator;
    var engine = try cdc.CDCEngine.init(ally, .{ .enabled = true, .sinks = &[_]cdc.CDCSink{.memory}, .batch_size = 256, .adaptive_flush = true, .min_batch_size = 128, .max_batch_size = 2048, .adapt_window_events = 256 });
    defer engine.deinit();

    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        try engine.emitChange(.insert, .node, @as(u64, @intCast(i)), null, null);
    }
    try engine.flushNow();
    const status = engine.getStatus();
    try std.testing.expect(status.peak_buffer > 0);
    try std.testing.expect(status.batch_adjustments >= 1);
    // Newly exposed diagnostics counter should be >= 0 (no malformed ingested here)
    try std.testing.expect(status.malformed_wal_records == 0);
}
