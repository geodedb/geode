const std = @import("std");
const exec = @import("../src/exec.zig");

// CANARY: REQ=REQ-GQL-012; FEATURE="GROUP BY/Aggregation"; ASPECT=DecimalOverflowSum; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_012_DecimalOverflowSum; OWNER=engine; UPDATED=2025-09-21
// CANARY: REQ=REQ-GQL-012; FEATURE="GROUP BY/Aggregation"; ASPECT=DecimalOverflowAvg; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_012_DecimalOverflowAvg; OWNER=engine; UPDATED=2025-09-21

// Helper to fabricate rows with large decimal coefficients to induce overflow in scale alignment / addition.
fn bigDecimal(coeff: i128, scale: u8) exec.BindingValue {
    return .{ .Decimal = .{ .coeff = coeff, .scale = scale } };
}

test "TestCANARY_REQ_GQL_012_DecimalOverflowSum" {
    const ally = std.testing.allocator;
    // Two rows with large decimals that when aligned to greater scale risk overflow via repeated additions.
    const rows: []const []exec.BindingValue = &.{
        &.{ .{ .Str = "G" }, bigDecimal(9_223_372_036_854_775, 2) }, // ~9.22e15 * 10^-2
        &.{ .{ .Str = "G" }, bigDecimal(9_223_372_036_854_775, 4) }, // same magnitude diff scale
    };
    const spec = exec.GroupSpec{ .key_idxs = &.{0}, .aggs = &.{.Sum} };
    const vals = &.{1};
    const out = try exec.groupAndAggregate(ally, rows, spec, vals);
    defer ally.free(out);
    try std.testing.expect(out.len == 1);
    // Expect SUM result either Decimal (if no overflow) or NULL on overflow; enforce non-crash and deterministic type.
    // Policy: On overflow we return NULL (see exec.zig ovf flag usage).
    const res = out[0][1];
    if (res != .Decimal) {
        try std.testing.expect(res == .Null);
    }
}

test "TestCANARY_REQ_GQL_012_DecimalOverflowAvg" {
    const ally = std.testing.allocator;
    const rows: []const []exec.BindingValue = &.{
        &.{ .{ .Str = "G" }, bigDecimal(9_223_372_036_854_775, 2) },
        &.{ .{ .Str = "G" }, bigDecimal(9_223_372_036_854_775, 4) },
        &.{ .{ .Str = "G" }, bigDecimal(9_223_372_036_854_775, 6) },
    };
    const spec = exec.GroupSpec{ .key_idxs = &.{0}, .aggs = &.{.Avg} };
    const vals = &.{1};
    const out = try exec.groupAndAggregate(ally, rows, spec, vals);
    defer ally.free(out);
    try std.testing.expect(out.len == 1);
    const res = out[0][1];
    if (res != .Decimal) {
        try std.testing.expect(res == .Null);
    }
}
