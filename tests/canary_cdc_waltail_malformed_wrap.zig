const std = @import("std");
const cdc = @import("../src/streaming/cdc_enhanced.zig");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=WALTailMalformedLogBufferWrap; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_WalTailMalformedLogBufferWrap; OWNER=streaming; UPDATED=2025-09-20

fn feedMalformed(engine: *cdc.CDCEngine, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) engine.ingestFromWalRecord(1, .node, @as(u64, i), "{bad") catch unreachable;
}

test "TestCANARY_REQ_GQL_042_CDC_WalTailMalformedLogBufferWrap" {
    const allocator = std.testing.allocator;
    var engine = try cdc.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc.CDCSink{.memory} });
    defer engine.deinit();

    // We trigger more than 32 snapshot events: counts 1, 100, 200, ... until > 3200 to force multiple overwrites.
    // Only snapshot points are recorded, so feed 3300 malformed records.
    feedMalformed(&engine, 3300);

    const json = try engine.malformedLogSnapshots(allocator);
    defer allocator.free(json);

    // Ensure that early snapshot (count=1) has been overwritten (should not appear) and latest (count=3200 or 3300 not snapshot) exists.
    // Snapshot counts present should include 3100 and 3200 but not 1.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":1") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":3100") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":3200") != null);
}
