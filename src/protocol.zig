const std = @import("std");

// Wire-neutral value types used by distributed coordination layers.
// Protobuf encoding happens at transport boundaries, not here.

pub const BindingValue = union(enum) {
    Null,
    Int: i64,
    Decimal: struct { coeff: i128, scale: u8 },
    Str: []const u8,
    Bool: bool,
    List: []BindingValue,
};

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

pub const Value = union(enum) {
    Null,
    Int: i64,
    Bool: bool,
    Str: []const u8,
    Float: f64,
};

// Compare two BindingValues with NULL handling according to NULLS FIRST/LAST policy.
// CANARY: REQ=REQ-DIST-CMP-001; FEATURE="Distributed Value Comparison"; ASPECT=Distributed; STATUS=TESTED; TEST=geodetestlab/specs/gql_distributed_queries.yml; OWNER=protocol; UPDATED=2026-02-03
pub fn compareBindingValues(a: BindingValue, b: BindingValue, nulls_first: bool) std.math.Order {
    const a_is_null = (a == .Null);
    const b_is_null = (b == .Null);
    if (a_is_null or b_is_null) {
        if (a_is_null and b_is_null) return .eq;
        if (nulls_first) {
            return if (a_is_null) .lt else .gt;
        }
        return if (a_is_null) .gt else .lt;
    }

    const rank = struct {
        fn of(v: BindingValue) u8 {
            return switch (v) {
                .Null => 0,
                .Bool => 1,
                .Int => 2,
                .Decimal => 3,
                .Str => 4,
                .List => 5,
            };
        }
    };
    const ra = rank.of(a);
    const rb = rank.of(b);
    if (ra != rb) return if (ra < rb) .lt else .gt;

    return switch (a) {
        .Null => .eq,
        .Bool => |av| {
            const bv = b.Bool;
            if (av == bv) return .eq;
            return if (av) .gt else .lt;
        },
        .Int => |av| {
            const bv = b.Int;
            if (av == bv) return .eq;
            return if (av < bv) .lt else .gt;
        },
        .Decimal => |ad| {
            const bd = b.Decimal;
            if (ad.scale == bd.scale) {
                if (ad.coeff == bd.coeff) return .eq;
                return if (ad.coeff < bd.coeff) .lt else .gt;
            }
            const max_scale: u8 = if (ad.scale > bd.scale) ad.scale else bd.scale;
            const a_adj = ad.coeff * std.math.pow(i128, 10, max_scale - ad.scale);
            const b_adj = bd.coeff * std.math.pow(i128, 10, max_scale - bd.scale);
            if (a_adj == b_adj) return .eq;
            return if (a_adj < b_adj) .lt else .gt;
        },
        .Str => |as| std.mem.order(u8, as, b.Str),
        .List => .eq,
    };
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
