const std = @import("std");
const cdc = @import("cdc_enhanced");

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("Expected substring '{s}' in diagnostics: {s}\n", .{ needle, haystack });
        return error.NotFound;
    }
}

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
    try engine.ingestFromWalRecord(1, .node, 1, good_payload);
    try engine.ingestFromWalRecord(1, .node, 2, good_payload);
    try engine.ingestFromWalRecord(1, .node, 3, bad_payload); // malformed 1 (ratio 1/3=0.333 >= warn)
    try engine.ingestFromWalRecord(1, .node, 4, good_payload); // ratio 1/4=0.25
    try engine.ingestFromWalRecord(1, .node, 5, bad_payload); // malformed 2 ratio 2/5=0.4 => abort threshold
    try engine.ingestFromWalRecord(1, .node, 6, bad_payload); // malformed 3 ratio 3/6=0.5

    const diag = try engine.exportDiagnostics(allocator);
    defer allocator.free(diag);

    try expectContains(diag, "\"guardrail_warn_triggered\":true");
    try expectContains(diag, "\"guardrail_abort_triggered\":true");
    // Timestamp assertions: presence and abort ts not zero. (Warn ts should also be non-zero.)
    try expectContains(diag, "\"first_warn_ts_ms\":");
    try expectContains(diag, "\"first_abort_ts_ms\":");
    // Weak heuristic to ensure abort ts not zero: absence of pattern 'first_abort_ts_ms":0,'
    if (std.mem.indexOf(u8, diag, "\"first_abort_ts_ms\":0") != null) {
        return error.Unexpected;
    }
}
