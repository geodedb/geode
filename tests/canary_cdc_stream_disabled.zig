const std = @import("std");
const cdc_mod = @import("../src/streaming/cdc_enhanced.zig");

// TestCANARY_REQ_GQL_042_CDC_ChangeStreamDisabled
// Ensure ingestChangeRecord is a no-op when CDC disabled.

test "TestCANARY_REQ_GQL_042_CDC_ChangeStreamDisabled" {
    const allocator = std.testing.allocator;
    var engine = try cdc_mod.CDCEngine.init(allocator, .{ .enabled = false, .sinks = &[_]cdc_mod.CDCSink{.memory}, .batch_size = 10 });
    defer engine.deinit();

    try engine.ingestChangeRecord(7, .node, 77, "{\"id\":77}");
    try engine.flushNow();

    try std.testing.expect(engine.total_events == 0);
}
