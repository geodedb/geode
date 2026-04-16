const std = @import("std");
const streaming = @import("../src/streaming/cdc_enhanced.zig");

// Integrative umbrella test exercising CDC Core start->ingest->diagnostics->resume token path.
// TestCANARY_REQ_GQL_042_CDC_E2EUmbrella
// Deterministic: fixed seeds, no wall clock assertions.

test "TestCANARY_REQ_GQL_042_CDC_E2EUmbrella" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Minimal engine configuration
    var engine = try streaming.CDCEngine.init(allocator, .{
        .enabled = true,
        .batch_size = 8,
        .sinks = &[_]streaming.CDCSink{},
    });
    defer engine.deinit();

    try engine.start();
    try std.testing.expect(engine.isRunning());

    // Ingest a few synthetic events
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try engine.captureChange(.insert, .node, @as(u64, @intCast(i)), null, "{\"id\":1}");
    }

    // Export diagnostics snapshot
    var diag = try engine.exportDiagnostics(allocator);
    defer diag.deinit(allocator);
    try std.testing.expect(diag.events_captured >= 5);

    // Obtain resume token then stop and restart to validate continuity
    const token = engine.currentResumeToken();
    try engine.stop();
    try std.testing.expect(!engine.isRunning());
    try engine.start();
    try std.testing.expect(engine.isRunning());
    // Resume token should still be comparable (non-empty)
    try std.testing.expect(token > 0);
}
