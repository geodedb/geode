const std = @import("std");
const testing = std.testing;
const cdc = @import("cdc_enhanced");

// Create exactly 6 attempts with 3 malformed to yield ratio 0.5.
// We assert the substring "malformed_ratio":0.5 appears (allow integer formatting edge: could be "0.5" or "0.5" depending on fmt).
// Since formatting uses {d} for f64, 0.5 should render as 0.5 (not scientific).

test "CDC malformed ratio precision 0.5" {
    const allocator = testing.allocator;
    const cfg = cdc.CDCConfig{
        .enabled = true,
        .sinks = &[_]cdc.CDCSink{.memory},
        .batch_size = 64,
        .flush_interval_ms = 10_000,
        .adaptive_flush = false,
        .malformed_warn_pct = 2.0, // disable
        .malformed_abort_pct = 3.0, // disable
        .malformed_snapshot_interval = 10,
        .malformed_hash_retain = 0,
    };

    var engine = try cdc.CDCEngine.init(allocator, cfg);
    defer engine.deinit();

    const good = "{\"id\":1}";
    const bad = "BAD";

    // Sequence: B,G,B,G,B,G (3 malformed of 6)
    try engine.ingestChangeRecord(1, .node, 1, bad);
    try engine.ingestChangeRecord(1, .node, 2, good);
    try engine.ingestChangeRecord(1, .node, 3, bad);
    try engine.ingestChangeRecord(1, .node, 4, good);
    try engine.ingestChangeRecord(1, .node, 5, bad);
    try engine.ingestChangeRecord(1, .node, 6, good);

    var diag = try engine.exportDiagnostics(allocator);
    defer diag.deinit(allocator);

    try testing.expectApproxEqAbs(@as(f64, 0.5), diag.malformed_ratio, 0.0001);
}
