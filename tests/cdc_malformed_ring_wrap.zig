const std = @import("std");
const cdc = @import("cdc_enhanced");

// The MalformedRing capacity is 32. We configure snapshot interval = 1 so every malformed increments ring.
// Feed 40 malformed records; confirm diagnostics has a snapshot array of size 32 and DOES NOT contain count 1 (overwritten).
// We can't easily parse JSON without pulling in a parser, so we do substring heuristics:
//  - Expect presence of last malformed count (e.g. 40) and absence of very early low count ("\"count\":1,")
//  - Expect presence of capacity-anchored later count (e.g. 32 or higher). This is heuristic but increases confidence.

test "CDC malformed ring wraps after capacity" {
    const allocator = std.testing.allocator;
    const cfg = cdc.CDCConfig{
        .enabled = true,
        .sinks = &[_]cdc.CDCSink{.memory},
        .batch_size = 128,
        .flush_interval_ms = 10_000, // avoid periodic flush interference
        .adaptive_flush = false,
        .malformed_warn_pct = 10.0, // disable thresholds effectively
        .malformed_abort_pct = 20.0,
        .malformed_snapshot_interval = 1, // snapshot each malformed
        .malformed_hash_retain = 0, // simplify diagnostics
    };

    var engine = try cdc.CDCEngine.init(allocator, cfg);
    defer engine.deinit();

    // Do not start thread; ingestion doesn't require background loop.

    const bad = "BAD";
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        try engine.ingestChangeRecord(1, .node, @intCast(i), bad);
    }

    var diag = try engine.exportDiagnostics(allocator);
    defer diag.deinit(allocator);

    try std.testing.expectEqual(@as(usize, cdc.CDCEngine.MalformedRing.CAP), diag.malformed_snapshots.items.len);

    var has40 = false;
    var has32 = false;
    var has1 = false;
    for (diag.malformed_snapshots.items) |snap| {
        if (snap.count == 40) has40 = true;
        if (snap.count == 32) has32 = true;
        if (snap.count == 1) has1 = true;
    }
    try std.testing.expect(has40);
    try std.testing.expect(has32);
    // Count 1 should have been overwritten after wrap; keep as soft assertion.
    try std.testing.expect(!has1);
}
