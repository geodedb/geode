// CANARY: REQ=REQ-GQL-012; FEATURE="GROUP BY/Aggregation"; ASPECT=HashAggDecimalEarlyState; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_012_HashAggDecimalEarlyState; OWNER=engine; UPDATED=2025-09-21
const std = @import("std");
const exec = @import("../src/exec.zig");

// This test feeds decimals with differing scales to SUM and AVG ensuring the output scale equals max input scale
// and the aggregated coeff matches scaled arithmetic, evidencing early decimal partial state handling.

test "TestCANARY_REQ_GQL_012_HashAggDecimalEarlyState" {
    const allocator = std.testing.allocator;
    var agg = exec.HashAggregator.init(allocator, 1024);
    defer agg.deinit();

    const key_val = exec.BindingValue{ .Int = 9 };
    const aggs = [_]exec.Agg{ .Sum, .Avg };

    // Values: 1.2 (coeff 12 scale1), 1.23 (123 s2), 1.234 (1234 s3)
    var inputs1 = [_]exec.BindingValue{ .{ .Decimal = .{ .coeff = 12, .scale = 1 } }, .{ .Decimal = .{ .coeff = 12, .scale = 1 } } };
    var kslice = [_]exec.BindingValue{key_val};
    try agg.addRow(&kslice, &inputs1, &aggs);
    var inputs2 = [_]exec.BindingValue{ .{ .Decimal = .{ .coeff = 123, .scale = 2 } }, .{ .Decimal = .{ .coeff = 123, .scale = 2 } } };
    try agg.addRow(&kslice, &inputs2, &aggs);
    var inputs3 = [_]exec.BindingValue{ .{ .Decimal = .{ .coeff = 1234, .scale = 3 } }, .{ .Decimal = .{ .coeff = 1234, .scale = 3 } } };
    try agg.addRow(&kslice, &inputs3, &aggs);

    const rows = try agg.getResults();
    defer allocator.free(rows);
    try std.testing.expect(rows.len == 1);
    const r = rows[0];
    // Sum: scale 3; values scaled to 3 => 1.200 + 1.230 + 1.234 = 3.664 coeff=3664 scale=3
    try std.testing.expect(r[1] == .Decimal and r[1].Decimal.scale == 3 and r[1].Decimal.coeff == 3664);
    // Avg: (3664 / 3) = 1221 truncated scale3 (represents 1.221)
    try std.testing.expect(r[2] == .Decimal and r[2].Decimal.scale == 3 and r[2].Decimal.coeff == 1221);
}
