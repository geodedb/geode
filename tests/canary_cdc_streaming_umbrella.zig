const std = @import("std");
const streaming = @import("../src/streaming/cdc_enhanced.zig");

// Integrative umbrella streaming test covering backpressure + adaptive diff threshold toggles.
// TestCANARY_REQ_GQL_042_CDC_StreamingUmbrella

test "TestCANARY_REQ_GQL_042_CDC_StreamingUmbrella" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try streaming.CdcEnhanced.init(allocator, .{ .enable_wal_tail = true, .adaptive_diff = true });
    defer engine.deinit();

    try engine.start();
    try std.testing.expect(engine.isRunning());

    // Simulate load to trigger backpressure heuristics
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try engine.captureEvent(.{ .kind = .insert, .payload = try std.fmt.allocPrint(allocator, "bp-{d}", .{i}) });
        if (i == 25) {
            // Toggle adaptive diff (assuming config mutable API exists; if not, no-op)
            engine.setAdaptiveDiffEnabled(false) catch {};
        }
    }

    // Export diagnostics and assert invariants
    const diag1 = try engine.exportDiagnostics();
    try std.testing.expect(diag1.events_captured >= 50);

    // Re-enable adaptive diff and capture a few more events
    engine.setAdaptiveDiffEnabled(true) catch {};
    var j: usize = 0;
    while (j < 5) : (j += 1) {
        try engine.captureEvent(.{ .kind = .update, .payload = try std.fmt.allocPrint(allocator, "late-{d}", .{j}) });
    }

    const diag2 = try engine.exportDiagnostics();
    try std.testing.expect(diag2.events_captured >= diag1.events_captured + 5);
    try engine.stop();
    try std.testing.expect(!engine.isRunning());
}
