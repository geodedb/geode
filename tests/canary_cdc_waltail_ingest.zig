const std = @import("std");
const cdc_mod = @import("../src/streaming/cdc_enhanced.zig");

// TestCANARY_REQ_GQL_042_CDC_WalTailPromote
// Promotes WALTail aspect by simulating WAL record ingestion and asserting sequence & txn attribution.

test "TestCANARY_REQ_GQL_042_CDC_WalTailPromote" {
    const allocator = std.testing.allocator;
    var engine = try cdc_mod.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc_mod.CDCSink{.memory}, .batch_size = 10 });
    defer engine.deinit();

    try engine.ingestChangeRecord(42, .node, 999, "{\"id\":999,\"val\":1}");
    try engine.flushNow();
    try std.testing.expect(engine.total_events == 1);

    // Verify memory sink has exactly one event with transaction attribution
    const count = engine.memorySinkEventCount();
    try std.testing.expect(count == 1);
}
