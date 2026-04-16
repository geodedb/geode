const std = @import("std");
const cdc = @import("../src/streaming/cdc_enhanced.zig");

// TestCANARY_REQ_GQL_042_CDC_EventCapture
// Verifies that events are captured when enabled, start is invoked, and flushed to memory sink.

test "TestCANARY_REQ_GQL_042_CDC_EventCapture" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = cdc.CDCConfig{
        .enabled = true,
        .sinks = &[_]cdc.CDCSink{.memory},
        .batch_size = 100, // avoid auto flush
        .flush_interval_ms = 10_000, // large so we control flush
    };

    var engine = try cdc.CDCEngine.init(allocator, cfg);
    defer engine.deinit();

    try engine.start();
    try std.testing.expect(engine.isRunning());

    // Emit several changes
    try engine.emitChange(.insert, .node, 1, null, "{\"id\":1}");
    try engine.emitChange(.update, .node, 1, "{\"id\":1}", "{\"id\":1,\"v\":2}");
    try engine.emitChange(.delete, .node, 1, "{\"id\":1,\"v\":2}", null);

    // Should still be buffered (no flush yet)
    const status_before = engine.getStatus();
    try std.testing.expect(status_before.total_events == 3);
    try std.testing.expect(engine.memorySinkEventCount() == 0); // not flushed yet

    // Force flush
    try engine.flushNow();
    try std.testing.expect(engine.memorySinkEventCount() == 3);

    engine.stop();
    try std.testing.expect(!engine.isRunning());
}
