const std = @import("std");
const cdc = @import("../src/streaming/cdc_enhanced.zig");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=DiagnosticsExport; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_DiagnosticsExport; OWNER=streaming; UPDATED=2025-09-20

test "TestCANARY_REQ_GQL_042_CDC_DiagnosticsExport" {
    const allocator = std.testing.allocator;
    var engine = try cdc.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc.CDCSink{.memory} });
    defer engine.deinit();

    // Feed some malformed and valid events
    try engine.ingestChangeRecord(1, .node, 1, "{bad"); // malformed
    try engine.ingestChangeRecord(1, .node, 2, "{also_bad"); // malformed
    try engine.ingestChangeRecord(1, .node, 3, "{\"ok\":true}"); // valid

    var diag = try engine.exportDiagnostics(allocator);
    defer diag.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), diag.malformed_change_records);
    try std.testing.expect(diag.malformed_snapshots.items.len > 0);
}
