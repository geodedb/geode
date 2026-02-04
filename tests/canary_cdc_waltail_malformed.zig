const std = @import("std");
const cdc_mod = @import("../src/streaming/cdc_enhanced.zig");

// TestCANARY_REQ_GQL_042_CDC_WalTailMalformed
// Ensures malformed WAL records (missing braces) are ignored.

test "TestCANARY_REQ_GQL_042_CDC_WalTailMalformed" {
    const allocator = std.testing.allocator;
    var engine = try cdc_mod.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc_mod.CDCSink{.memory}, .batch_size = 8 });
    defer engine.deinit();

    // Good record
    try engine.ingestChangeRecord(1, .node, 1, "{\"id\":1}");
    // Malformed records (101 total to trigger logging at 1 and 100)
    var i: usize = 0;
    while (i < 101) : (i += 1) {
        if (i % 2 == 0) {
            try engine.ingestChangeRecord(1000 + @as(u64, @intCast(i)), .node, 2 + i, "id:bad");
        } else {
            try engine.ingestChangeRecord(1000 + @as(u64, @intCast(i)), .node, 2 + i, "{bad");
        }
    }

    try engine.flushNow();
    try std.testing.expect(engine.total_events == 1);
    const status = engine.getStatus();
    try std.testing.expect(status.malformed_wal_records == 101);
}
