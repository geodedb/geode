// CANARY: REQ=REQ-GQL-012; FEATURE="GROUP BY/Aggregation"; ASPECT=HashAggDecimalSpillMerge; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_012_HashAggDecimalSpillMerge; OWNER=engine; UPDATED=2025-09-21
const std = @import("std");
const exec = @import("../src/exec.zig");

// This test validates that decimal SUM and AVG preserve scale after spilling multiple segments.
// We simulate aggregation of 100 decimal values 1.23 (coeff=123, scale=2) expecting SUM=123*100=12300 (scale 2) and AVG=123 (scale 2, representing 1.23).

test "TestCANARY_REQ_GQL_012_HashAggDecimalSpillMerge" {
    const ally = std.testing.allocator;
    var agg = exec.HashAggregator.init(ally, 512); // tiny memory limit triggers spilling
    defer agg.deinit();

    const key_val = exec.BindingValue{ .Int = 7 };
    const aggs = [_]exec.Agg{ .Sum, .Avg };

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var key_slice = [_]exec.BindingValue{key_val};
        var inputs = [_]exec.BindingValue{ .{ .Decimal = .{ .coeff = 123, .scale = 2 } }, .{ .Decimal = .{ .coeff = 123, .scale = 2 } } };
        try agg.addRow(&key_slice, &inputs, &aggs);
    }
    try agg.flushSegment(&aggs);
    const rows = try agg.getResults();
    defer ally.free(rows);
    try std.testing.expect(rows.len == 1);
    const r = rows[0];
    try std.testing.expect(r.len == 1 + aggs.len);
    // SUM should be Decimal coeff=12300 scale=2 (represents 123.00) because we added 100 * 1.23 = 123.00
    try std.testing.expect(r[1] == .Decimal and r[1].Decimal.scale == 2 and r[1].Decimal.coeff == 12300);
    // AVG should be Decimal coeff=123 scale=2 (1.23)
    try std.testing.expect(r[2] == .Decimal and r[2].Decimal.scale == 2 and r[2].Decimal.coeff == 123);
}
