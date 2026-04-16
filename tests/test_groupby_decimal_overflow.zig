const std = @import("std");
const exec = @import("../src/exec.zig");
const ast = @import("../src/ast.zig");

// CANARY: REQ=REQ-GQL-012; FEATURE="GROUP BY/Aggregation"; ASPECT=DecimalOverflowHandling; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_012_DecimalOverflowHandling; OWNER=engine; UPDATED=2025-09-21
// Validates deterministic NULL on decimal SUM/AVG overflow (no wrap) per implementation-defined policy (document in flagger later).

test "TestCANARY_REQ_GQL_012_DecimalOverflowHandling" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Construct rows with one group key 'g' and decimal values large enough to trigger overflow when summed.
    // Using coeff near i128 max; scale differences to exercise scale alignment overflow paths.
    const max_i128: i128 = @as(i128, @bitCast(@as(u128, 0x7fffffffffffffff_ffffffffffffffff))); // largest positive signed 128

    var rows = std.ArrayList([]const exec.BindingValue).init(allocator);
    defer rows.deinit();

    // Append helper rows inline (g_key, decimal_value)
    {
        var r = try allocator.alloc(exec.BindingValue, 2);
        r[0] = .{ .Str = "g" };
        r[1] = .{ .Decimal = .{ .coeff = max_i128 - 5, .scale = 2 } };
        try rows.append(r);
    }
    {
        var r2 = try allocator.alloc(exec.BindingValue, 2);
        r2[0] = .{ .Str = "g" };
        r2[1] = .{ .Decimal = .{ .coeff = 900, .scale = 5 } };
        try rows.append(r2);
    }

    const spec = exec.GroupSpec{ .key_idxs = &.{0}, .aggs = &.{ .Sum, .Avg } };
    const value_idxs = [_]usize{ 1, 1 };
    const out = try exec.groupAndAggregate(allocator, rows.items, spec, &value_idxs);
    defer {
        for (out) |o| allocator.free(o);
        allocator.free(out);
        for (rows.items) |r| allocator.free(r);
    }
    try std.testing.expect(out.len == 1);
    const row = out[0];
    // Layout: key, SUM(decimal), AVG(decimal)
    try std.testing.expect(row[1] == .Null); // SUM overflow => NULL
    try std.testing.expect(row[2] == .Null); // AVG overflow => NULL
}
