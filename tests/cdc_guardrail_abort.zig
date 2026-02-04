const std = @import("std");
const cdc = @import("cdc_enhanced");

// This test pushes malformed ratio past both warn (0.2) and abort (0.4) thresholds.
// Plan: good, good, bad, good, bad, bad -> attempts=6 malformed=3 ratio=0.5 (>=0.4 abort)
// Ensures both flags latched true.

test "CDC guardrail abort triggers (warn & abort true)" {
    const allocator = std.testing.allocator;
    const cfg = cdc.CDCConfig{
        .enabled = true,
        .sinks = &[_]cdc.CDCSink{.memory},
        .batch_size = 32,
        .flush_interval_ms = 500,
        .adaptive_flush = false,
        .malformed_warn_pct = 0.20,
        .malformed_abort_pct = 0.40,
        .malformed_snapshot_interval = 2,
        .malformed_hash_retain = 4,
    };

    var engine = try cdc.CDCEngine.init(allocator, cfg);
    defer engine.deinit();
    try engine.start();
    defer engine.stop();

    const good_payload = "{\"id\":1}";
    const bad_payload = "BAD";

    // Sequence: G,G,B,G,B,B  => malformed=3 attempts=6 ratio=0.5
    try engine.ingestChangeRecord(1, .node, 1, good_payload);
    try engine.ingestChangeRecord(1, .node, 2, good_payload);
    try engine.ingestChangeRecord(1, .node, 3, bad_payload); // malformed 1 (ratio 1/3=0.333 >= warn)
    try engine.ingestChangeRecord(1, .node, 4, good_payload); // ratio 1/4=0.25
    try engine.ingestChangeRecord(1, .node, 5, bad_payload); // malformed 2 ratio 2/5=0.4 => abort threshold
    try engine.ingestChangeRecord(1, .node, 6, bad_payload); // malformed 3 ratio 3/6=0.5

    var diag = try engine.exportDiagnostics(allocator);
    defer diag.deinit(allocator);

    try std.testing.expect(diag.guardrail_warn_triggered);
    try std.testing.expect(diag.guardrail_abort_triggered);
    try std.testing.expect(diag.first_warn_ts_ms > 0);
    try std.testing.expect(diag.first_abort_ts_ms > 0);
}
