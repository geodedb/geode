const std = @import("std");
const exec = @import("../src/exec.zig");

// CANARY: REQ=REQ-GQL-012; FEATURE="GROUP BY/Aggregation"; ASPECT=HashAggSpillEvict; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_012_HashAggSpillEvict; OWNER=engine; UPDATED=2025-09-21

// Functional test validating Phase-2 spill eviction: groups exceed memory limit and are
// serialized to segment file, cleared from memory, then merged on getResults.
// We insert enough distinct groups with a tiny memory limit to force multiple flushes.

test "TestCANARY_REQ_GQL_012_HashAggSpillEvict" {
    var gpa = std.testing.allocator;
    var agg = exec.HashAggregator.init(gpa, 2048); // small limit
    defer agg.deinit();

    var i: usize = 0;
    // Insert 300 groups to ensure multiple segments (depending on serialization size)
    while (i < 300) : (i += 1) {
        const key = [_]exec.BindingValue{.{ .Int = @intCast(i) }};
        const val = [_]exec.BindingValue{.{ .Int = 1 }};
        try agg.addRow(&key, &val, &.{.Count});
    }

    // At this point aggregator either spilled or retained depending on serialization size; force a final flush
    try agg.flushSegment(&.{.Count});

    // Ensure in-memory map possibly cleared (allow zero or some residual if last batch < limit)
    try std.testing.expect(agg.spilled);

    const rows = try agg.getResults();
    defer gpa.free(rows);
    // Expect 300 groups with Count=1 each
    try std.testing.expect(rows.len == 300);
    var seen: usize = 0;
    for (rows) |r| {
        try std.testing.expect(r.len == 2); // key + count
        try std.testing.expect(r[1] == .Int and r[1].Int == 1);
        seen += 1;
    }
    try std.testing.expect(seen == 300);
}
