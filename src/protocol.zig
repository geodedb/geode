const std = @import("std");
const value_types = @import("value_types.zig");
const ast = @import("gql/ast.zig");
const sort_utils = @import("execution/return_and_sorting.zig");

// Internal value types for distributed coordination layers.
// Protobuf encoding happens at transport boundaries.

pub const Value = value_types.Value;
pub const BindingValue = value_types.Value;

pub const BindingRow = struct {
    cols: []const BindingValue,

    pub fn get(self: BindingRow, idx: usize) BindingValue {
        if (idx < self.cols.len) return self.cols[idx];
        return .{ .Null = {} };
    }
};

pub const ColumnDef = struct {
    name: []const u8,
    data_type: []const u8 = "ANY",
};

// Compare two BindingValues with NULL handling according to NULLS FIRST/LAST policy.
// CANARY: REQ=REQ-DIST-CMP-001; FEATURE="Distributed Value Comparison"; ASPECT=Distributed; STATUS=TESTED; TEST=geodetestlab/specs/gql_distributed_queries.yml; OWNER=protocol; UPDATED=2026-02-03
pub fn compareBindingValues(a: BindingValue, b: BindingValue, nulls_first: bool) std.math.Order {
    const policy: ast.OrderBy.NullsPolicy = if (nulls_first) .first else .last;
    const cmp = sort_utils.compareValuesWithNullsPolicy(a, b, policy);
    if (cmp < 0) return .lt;
    if (cmp > 0) return .gt;
    return .eq;
}

// Compare two binding rows by specified column indices with order directions.
// CANARY: REQ=REQ-DIST-ROW-CMP-001; FEATURE="Distributed Row Comparison"; ASPECT=Distributed; STATUS=TESTED; TEST=geodetestlab/specs/gql_distributed_queries.yml; OWNER=protocol; UPDATED=2026-02-03
pub fn compareBindingRows(
    a: BindingRow,
    b: BindingRow,
    order_col_indices: []const usize,
    order_ascending: []const bool,
    nulls_first: bool,
) std.math.Order {
    for (order_col_indices, 0..) |col_idx, key_idx| {
        const av = a.get(col_idx);
        const bv = b.get(col_idx);
        const cmp = compareBindingValues(av, bv, nulls_first);
        if (cmp == .eq) continue;

        const ascending = if (key_idx < order_ascending.len) order_ascending[key_idx] else true;
        if (ascending) return cmp;
        return if (cmp == .lt) .gt else .lt;
    }
    return .eq;
}

test "compareBindingValues respects null policy" {
    const a = BindingValue{ .Null = {} };
    const b = BindingValue{ .Int = 1 };
    try std.testing.expect(compareBindingValues(a, b, true) == .lt);
    try std.testing.expect(compareBindingValues(a, b, false) == .gt);
}

test "compareBindingRows respects order keys" {
    const row_a = BindingRow{ .cols = &.{ BindingValue{ .Int = 1 }, BindingValue{ .Str = "b" } } };
    const row_b = BindingRow{ .cols = &.{ BindingValue{ .Int = 1 }, BindingValue{ .Str = "a" } } };
    const cols = [_]usize{1};
    const asc = [_]bool{true};
    try std.testing.expect(compareBindingRows(row_a, row_b, &cols, &asc, true) == .gt);
}
