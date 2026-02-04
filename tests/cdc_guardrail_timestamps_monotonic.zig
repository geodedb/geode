const std = @import("std");
const cdc = @import("cdc_enhanced");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=GuardrailTimestampsMonotonic; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_GuardrailTimestampsMonotonic; OWNER=streaming; UPDATED=2025-09-20

test "CDC guardrail timestamps monotonic" {
    const allocator = std.testing.allocator;
    var engine = try cdc.CDCEngine.init(allocator, cdc.CDCConfig{
        .enabled = true,
        .sinks = &[_]cdc.CDCSink{.memory},
        .malformed_warn_pct = 0.10,
        .malformed_abort_pct = 0.50,
    });
    defer engine.deinit();

    // Feed malformed records gradually to cross warn then abort thresholds
    // We target 10 attempts: warn after first (ratio=1.0), abort after half threshold: need >=5 malformed to hit 0.5
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try engine.ingestChangeRecord(1, .node, @intCast(i), "bad_payload");
    }

    var diag = try engine.exportDiagnostics(allocator);
    defer diag.deinit(allocator);
    try std.testing.expect(diag.first_warn_ts_ms > 0);
    try std.testing.expect(diag.first_abort_ts_ms > 0);
    try std.testing.expect(diag.first_warn_ts_ms <= diag.first_abort_ts_ms);
}
