const std = @import("std");
const testing = std.testing;
const cdc = @import("cdc_enhanced");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=BackpressureToggle; STATUS=TESTED; TEST=unit_CDC_backpressure_toggle; OWNER=cdc; UPDATED=2025-09-20

fn makeEngine(gpa: std.mem.Allocator, watermark: usize) !*cdc.CDCEngine {
    const cfg = cdc.CDCConfig{
        .enabled = true,
        .warn_pct = 0.5,
        .abort_pct = 0.9,
        .snapshot_interval = 4,
        .hash_retain = 8,
        .adaptive_flush = false,
        .batch_size = 16,
        .pending_backpressure_watermark = watermark,
    };
    const eng = try gpa.create(cdc.CDCEngine);
    eng.* = try cdc.CDCEngine.init(gpa, cfg);
    return eng;
}

test "unit: CDC backpressure toggles when threshold crossed" {
    var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa_allocator.deinit());
    const gpa = gpa_allocator.allocator();

    const eng = try makeEngine(gpa, 3);
    defer eng.deinit(gpa);

    // Add fewer than watermark events
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        try eng.captureEvent(gpa, .{ .kind = .InsertNode, .payload = "{}" });
    }
    const diag1 = try eng.exportDiagnostics(gpa);
    defer gpa.free(diag1);
    try testing.expect(std.mem.indexOf(u8, diag1, "\"backpressure\":false") != null);

    // Cross watermark
    try eng.captureEvent(gpa, .{ .kind = .InsertNode, .payload = "{}" });
    try eng.captureEvent(gpa, .{ .kind = .InsertNode, .payload = "{}" });
    const diag2 = try eng.exportDiagnostics(gpa);
    defer gpa.free(diag2);
    try testing.expect(std.mem.indexOf(u8, diag2, "\"backpressure\":true") != null);
}
