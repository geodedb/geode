const std = @import("std");
const cdc = @import("../src/streaming/cdc_enhanced.zig");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=ChangeStreamMalformedLogBuffer; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_042_CDC_ChangeStreamMalformedLogBuffer; OWNER=streaming; UPDATED=2026-11-14

// This test feeds 100 malformed change records and validates that the ring buffer captured
// snapshots for count=1 and count=100 (they will be the only two entries).
// We then parse the JSON produced by malformedLogSnapshots and assert ordering.

fn feedMalformed(engine: *cdc.CDCEngine, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // malformed string missing trailing brace
        engine.ingestChangeRecord(1, .node, @as(u64, i), "{not_json") catch unreachable;
    }
}

test "TestCANARY_REQ_GQL_042_CDC_ChangeStreamMalformedLogBuffer" {
    const allocator = std.testing.allocator;
    var engine = try cdc.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc.CDCSink{.memory} });
    defer engine.deinit();

    // Feed 100 malformed records.
    feedMalformed(&engine, 100);

    // Obtain snapshots JSON
    const json_bytes = try engine.malformedLogSnapshots(allocator);
    defer allocator.free(json_bytes);

    // Expect two entries: count 1 and count 100
    // Simple parse: ensure substrings exist and order is ascending chronological
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"count\":100") != null);

    const idx1 = std.mem.indexOf(u8, json_bytes, "\"count\":1").?;
    const idx100 = std.mem.indexOf(u8, json_bytes, "\"count\":100").?;
    try std.testing.expect(idx1 < idx100);

    // Also assert malformed counter == 100
    const status = engine.getStatus();
    try std.testing.expect(status.malformed_change_records == 100);
}
