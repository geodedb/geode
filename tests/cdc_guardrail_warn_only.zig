const std = @import("std");
const cdc = @import("cdc_enhanced");

// This test configures low malformed warn threshold and higher abort threshold.
// It then feeds malformed WAL payloads to cross warn but not abort and validates flag states.
// We choose warn=0.3 abort=0.8 and create a sequence of attempts where malformed ratio ~0.5 would exceed abort if we pushed further.
// Here we stop right after hitting warn (>=0.3) but before reaching 0.8.
// Attempt plan:
//  - Total attempts: 4 (3 malformed, 1 valid) yields ratio 0.75 (would exceed abort) -> so we avoid 3 malformed.
//  - Instead use 2 malformed + 5 valid => 7 attempts, ratio = 2/7 ≈ 0.2857 < 0.3 (still below warn)
//  - Then add one more malformed (now 3/8 = 0.375) -> triggers warn but < abort.
// Therefore sequence: M, V, M, V, V, V, V, M.
// Validate: guardrail_warn_triggered true, guardrail_abort_triggered false.

test "CDC guardrail warn only triggers before abort" {
    const allocator = std.testing.allocator;
    const cfg = cdc.CDCConfig{
        .enabled = true,
        .sinks = &[_]cdc.CDCSink{.memory},
        .batch_size = 16,
        .flush_interval_ms = 500,
        .adaptive_flush = false,
        .malformed_warn_pct = 0.30,
        .malformed_abort_pct = 0.80,
        .malformed_snapshot_interval = 2,
        .malformed_hash_retain = 4,
    };

    var engine = try cdc.CDCEngine.init(allocator, cfg);
    defer engine.deinit();
    try engine.start();
    defer engine.stop();

    const malformed_payload = "BAD"; // not JSON so treated malformed
    const good_payload = "{\"id\":1}";

    // Strategy: accumulate attempts keeping ratio < warn until we choose to cross it.
    // Start with 3 good, 1 bad -> ratio = 1/4 = 0.25 (<0.30)
    try engine.ingestChangeRecord(1, .node, 1, good_payload); // good 1
    try engine.ingestChangeRecord(1, .node, 2, good_payload); // good 2
    try engine.ingestChangeRecord(1, .node, 3, good_payload); // good 3
    try engine.ingestChangeRecord(1, .node, 4, malformed_payload); // bad 1 (ratio 1/4 = 0.25)

    // Add one more good: ratio 1/5 = 0.20
    try engine.ingestChangeRecord(1, .node, 5, good_payload);

    // Add second malformed: ratio 2/6 = 0.333... -> crosses warn (>=0.30) but < abort (0.80)
    try engine.ingestChangeRecord(1, .node, 6, malformed_payload); // bad 2

    // Ensure we did not accidentally trigger abort by keeping malformed far from 80%.
    // Add two more good: ratio 2/8 = 0.25 (drops below warn but flag stays latched true; expected behavior)
    try engine.ingestChangeRecord(1, .node, 7, good_payload);
    try engine.ingestChangeRecord(1, .node, 8, good_payload);

    var diag = try engine.exportDiagnostics(allocator);
    defer diag.deinit(allocator);

    try std.testing.expect(diag.guardrail_warn_triggered);
    try std.testing.expect(!diag.guardrail_abort_triggered);
    try std.testing.expect(diag.first_warn_ts_ms > 0);
    try std.testing.expect(diag.first_abort_ts_ms == 0);
}
