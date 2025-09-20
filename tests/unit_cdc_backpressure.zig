const std = @import("std");
const testing = std.testing;
const cdc = @import("cdc_enhanced");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=Backpressure; STATUS=TESTED; TEST=unit_CDC_backpressure_flag; OWNER=streaming; UPDATED=2025-09-20

test "CDC backpressure flag toggles when pending exceeds watermark" {
    const allocator = testing.allocator;
    var engine = try cdc.CDCEngine.init(allocator, cdc.CDCConfig{
        .enabled = true,
        .sinks = &[_]cdc.CDCSink{.memory},
        .batch_size = 10_000, // large to avoid auto flush
        .pending_backpressure_watermark = 5,
    });
    defer engine.deinit();

    try engine.start();

    // Capture 6 events without flushing (batch_size larger than 6)
    var i: u64 = 0;
    while (i < 6) : (i += 1) {
        try engine.captureChange(.insert, .node, i, null, "{\"id\":1}");
    }

    const diag = try engine.exportDiagnostics(allocator);
    defer allocator.free(diag);
    try testing.expect(std.mem.indexOf(u8, diag, "\"backpressure\":true") != null);
}
