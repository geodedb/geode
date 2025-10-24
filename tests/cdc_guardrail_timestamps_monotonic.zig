const std = @import("std");
const cdc = @import("cdc_enhanced");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=GuardrailTimestampsMonotonic; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_GuardrailTimestampsMonotonic; OWNER=streaming; UPDATED=2025-09-20

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
        try engine.ingestFromWalRecord(1, .node, @intCast(i), "bad_payload");
    }

    const diag = try engine.exportDiagnostics(allocator);
    defer allocator.free(diag);
    const warn_ts = parseField(diag, "\"first_warn_ts_ms\":").?;
    const abort_ts = parseField(diag, "\"first_abort_ts_ms\":").?;
    try std.testing.expect(warn_ts > 0);
    try std.testing.expect(abort_ts > 0);
    try std.testing.expect(warn_ts <= abort_ts);
}
