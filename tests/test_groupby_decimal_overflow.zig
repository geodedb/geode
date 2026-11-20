const std = @import("std");
const exec = @import("geode").exec;

// CANARY: REQ=REQ-GQL-012; FEATURE="GROUP BY/Aggregation"; ASPECT=DecimalOverflowHandling; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_012_DecimalOverflowHandling; OWNER=engine; UPDATED=2026-11-13
// Validates deterministic NULL on decimal SUM/AVG overflow (no wrap) per implementation-defined policy.
//
// SONNY-6467 item 5: no step compiled this file (it imported
// ../src/exec.zig, outside the test module, and used the pre-0.16
// ArrayList API), and it freed only the outer slice of
// groupAndAggregate's result. Now `zig build test-groupby-decimal-overflow`.

test "TestCANARY_REQ_GQL_012_DecimalOverflowHandling" {
    const allocator = std.testing.allocator;

    // One group key 'g' and decimal values large enough to overflow when summed:
    // coeff near i128 max, with a scale difference for the alignment path.
    const max_i128: i128 = std.math.maxInt(i128);

    var rows: std.ArrayList([]const exec.BindingValue) = .empty;
    defer {
        for (rows.items) |r| allocator.free(r);
        rows.deinit(allocator);
    }
    {
        const r = try allocator.alloc(exec.BindingValue, 2);
        r[0] = .{ .Str = "g" };
        r[1] = .{ .Decimal = .{ .coeff = max_i128 - 5, .scale = 2 } };
        try rows.append(allocator, r);
    }
    {
        const r2 = try allocator.alloc(exec.BindingValue, 2);
        r2[0] = .{ .Str = "g" };
        r2[1] = .{ .Decimal = .{ .coeff = 900, .scale = 5 } };
        try rows.append(allocator, r2);
    }

    const spec = exec.GroupSpec{ .key_idxs = &.{0}, .aggs = &.{ .Sum, .Avg } };
    const value_idxs = [_]usize{ 1, 1 };
    const out = try exec.groupAndAggregate(allocator, rows.items, spec, &value_idxs);
    defer exec.freeGroupedRows(allocator, out);
    try std.testing.expect(out.len == 1);
    const row = out[0];
    // Layout: key, SUM(decimal), AVG(decimal)
    try std.testing.expect(row[1] == .Null); // SUM overflow => NULL
    try std.testing.expect(row[2] == .Null); // AVG overflow => NULL
}
