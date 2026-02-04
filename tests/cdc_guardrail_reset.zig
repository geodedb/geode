const std = @import("std");
const cdc = @import("cdc_enhanced");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=GuardrailReset; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_GuardrailReset; OWNER=streaming; UPDATED=2025-09-20

test "CDC guardrail reset lifecycle" {
    const allocator = std.testing.allocator;
    var engine = try cdc.CDCEngine.init(allocator, cdc.CDCConfig{
        .enabled = true,
        .sinks = &[_]cdc.CDCSink{.memory},
        .malformed_warn_pct = 0.10,
        .malformed_abort_pct = 0.90,
    });
    defer engine.deinit();

    // Trigger warn (10 malformed out of 10 attempts => ratio=1.0 > warn threshold)
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try engine.ingestChangeRecord(1, .node, @intCast(i), "not_json");
    }

    var first_warn_before: i64 = 0;
    {
        var diag = try engine.exportDiagnostics(allocator);
        defer diag.deinit(allocator);
        try std.testing.expect(diag.guardrail_warn_triggered);
        first_warn_before = diag.first_warn_ts_ms;
        try std.testing.expect(first_warn_before > 0);
    }

    // Reset
    engine.resetGuardrailState();

    {
        var diag = try engine.exportDiagnostics(allocator);
        defer diag.deinit(allocator);
        try std.testing.expect(!diag.guardrail_warn_triggered);
        try std.testing.expect(!diag.guardrail_abort_triggered);
        try std.testing.expect(diag.first_warn_ts_ms == 0);
        try std.testing.expect(diag.first_abort_ts_ms == 0);
    }

    // Retrigger warn with additional malformed records (ratio still high)
    i = 10;
    while (i < 20) : (i += 1) {
        try engine.ingestChangeRecord(1, .node, @intCast(i), "not_json_again");
    }

    {
        var diag = try engine.exportDiagnostics(allocator);
        defer diag.deinit(allocator);
        try std.testing.expect(diag.first_warn_ts_ms > first_warn_before);
    }
}
