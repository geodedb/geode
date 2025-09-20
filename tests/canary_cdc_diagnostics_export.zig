const std = @import("std");
const cdc = @import("../src/streaming/cdc_enhanced.zig");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=DiagnosticsExport; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_DiagnosticsExport; OWNER=streaming; UPDATED=2025-09-20

test "TestCANARY_REQ_GQL_042_CDC_DiagnosticsExport" {
    const allocator = std.testing.allocator;
    var engine = try cdc.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc.CDCSink{.memory} });
    defer engine.deinit();

    // Feed some malformed and valid events
    try engine.ingestFromWalRecord(1, .node, 1, "{bad"); // malformed
    try engine.ingestFromWalRecord(1, .node, 2, "{also_bad"); // malformed
    try engine.ingestFromWalRecord(1, .node, 3, "{\"ok\":true}"); // valid

    const diag = try engine.exportDiagnostics(allocator);
    defer allocator.free(diag);
    // Expect keys and counts
    try std.testing.expect(std.mem.indexOf(u8, diag, "\"malformed_wal_records\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag, "\"malformed_snapshots\":[") != null);
}
