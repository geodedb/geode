const std = @import("std");
const cdc = @import("cdc_enhanced");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=GuardrailReset; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_GuardrailReset; OWNER=streaming; UPDATED=2025-09-20

fn parseField(json: []const u8, field: []const u8) ?i64 {
    if (std.mem.indexOf(u8, json, field)) |idx| {
        const slice = json[idx + field.len ..];
        var it = std.mem.tokenizeAny(u8, slice, ",}\n ");
        if (it.next()) |tok| {
            return std.fmt.parseInt(i64, tok, 10) catch null;
        }
    }
    return null;
}

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
        try engine.ingestFromWalRecord(1, .node, @intCast(i), "not_json");
    }

    var diag = try engine.exportDiagnostics(allocator);
    defer allocator.free(diag);
    try std.testing.expect(std.mem.indexOf(u8, diag, "\"guardrail_warn_triggered\":true") != null);
    const first_warn_before = parseField(diag, "\"first_warn_ts_ms\":").?;
    try std.testing.expect(first_warn_before > 0);

    // Reset
    engine.resetGuardrailState();

    diag = try engine.exportDiagnostics(allocator);
    defer allocator.free(diag);
    try std.testing.expect(std.mem.indexOf(u8, diag, "\"guardrail_warn_triggered\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag, "\"guardrail_abort_triggered\":false") != null);
    const first_warn_after_reset = parseField(diag, "\"first_warn_ts_ms\":").?;
    const first_abort_after_reset = parseField(diag, "\"first_abort_ts_ms\":").?;
    try std.testing.expect(first_warn_after_reset == 0);
    try std.testing.expect(first_abort_after_reset == 0);

    // Retrigger warn with additional malformed records (ratio still high)
    i = 10;
    while (i < 20) : (i += 1) {
        try engine.ingestFromWalRecord(1, .node, @intCast(i), "not_json_again");
    }

    diag = try engine.exportDiagnostics(allocator);
    defer allocator.free(diag);
    const first_warn_retrigger = parseField(diag, "\"first_warn_ts_ms\":").?;
    try std.testing.expect(first_warn_retrigger > first_warn_before);
}
