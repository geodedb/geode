const std = @import("std");
const ast = @import("gql/ast.zig");
const planner = @import("planner.zig");
const printer = @import("gql/print.zig");
const stdx = std;

pub const Row = struct {
    // For this minimal harness, a single key expression (temporal literal) to sort by.
    key: ast.Expr,
    // An identifier to test stability.
    id: usize,
};

pub fn stableOrderByTemporal(rows: []Row, desc: bool, nulls_policy: ?ast.OrderBy.NullsPolicy, ctx: planner.SessionContext, ally: std.mem.Allocator) !void {
    // Sort indices to keep original stability; break ties by original index.
    const idxs = try ally.alloc(usize, rows.len);
    defer ally.free(idxs);
    for (idxs, 0..) |*p, i| p.* = i;
    const Ctx = struct {
        rows: []Row,
        desc: bool,
        nulls_policy: ?ast.OrderBy.NullsPolicy,
        ctx: planner.SessionContext,
    };
    const sctx = Ctx{ .rows = rows, .desc = desc, .nulls_policy = nulls_policy, .ctx = ctx };
    std.sort.pdq(usize, idxs, sctx, struct {
        fn isNull(e: ast.Expr) bool {
            return e == .Null;
        }
        fn less(sc: Ctx, a: usize, b: usize) bool {
            const ra = sc.rows[a];
            const rb = sc.rows[b];
            const a_is_null = isNull(ra.key);
            const b_is_null = isNull(rb.key);
            if (a_is_null or b_is_null) {
                // If both null, stable tie-break
                if (a_is_null and b_is_null) return a < b;
                // If only one is null, use nulls_policy
                const np = sc.nulls_policy orelse ast.OrderBy.NullsPolicy.default;
                if (np == .first) return a_is_null;
                if (np == .last) return !a_is_null;
                // Default: nulls last for ASC, first for DESC (common SQL default)
                if (sc.desc) return !a_is_null; // DESC: nulls first
                return !b_is_null; // ASC: nulls last
            }
            const cmp = planner.compareTemporalForOrder(ra.key, rb.key, sc.ctx) catch {
                // Fallback to lexicographic stringify on error.Invalid
                const tmp_ally = std.heap.page_allocator;
                const sa = printer.stringifyExprAlloc(tmp_ally, ra.key, .{}) catch return a < b;
                defer tmp_ally.free(sa);
                const sb = printer.stringifyExprAlloc(tmp_ally, rb.key, .{}) catch return a < b;
                defer tmp_ally.free(sb);
                const ord = std.mem.order(u8, sa, sb);
                if (sc.desc) return ord == .gt else return ord == .lt;
            };
            if (sc.desc) {
                if (cmp == 0) return a < b; // stable tie-breaker
                return cmp > 0;
            } else {
                if (cmp == 0) return a < b;
                return cmp < 0;
            }
        }
    }.less);
    // Reorder rows in-place according to idxs
    var tmp = try ally.alloc(Row, rows.len);
    defer ally.free(tmp);
    for (idxs, 0..) |i, j| tmp[j] = rows[i];
    std.mem.copyForwards(Row, rows, tmp);
}

test "stable ORDER BY with cross-timezone equivalence and local attach" {
    const ally = std.testing.allocator;
    const ctx = planner.SessionContext{ .session_offset_minutes = 0 };
    var rows: [4]Row = .{
        .{ .id = 0, .key = .{ .DateTime = .{ .raw = "2024-01-01T10:00Z", .parsed = try @import("temporal.zig").parseDateTime("2024-01-01T10:00Z", true) } } },
        .{ .id = 1, .key = .{ .DateTime = .{ .raw = "2024-01-01T11:00+01:00", .parsed = try @import("temporal.zig").parseDateTime("2024-01-01T11:00+01:00", true) } } },
        .{ .id = 2, .key = .{ .DateTime = .{ .raw = "2024-01-01T09:00Z", .parsed = try @import("temporal.zig").parseDateTime("2024-01-01T09:00Z", true) } } },
        .{ .id = 3, .key = .{ .LocalDateTime = .{ .raw = "2024-01-01T10:00", .parsed = try @import("temporal.zig").parseDateTime("2024-01-01T10:00", false) } } },
    };
    // Ascending sort should place 09:00Z first; 10:00Z, 11:00+01:00, and local 10:00 (session 0) are equal instants.
    try stableOrderByTemporal(&rows, false, null, ctx, ally);
    try std.testing.expect(rows[0].id == 2);
    // The next three can be in original relative order among equal keys due to stability: ids 0,1,3 should preserve input order 0,1,3.
    try std.testing.expect(rows[1].id == 0);
    try std.testing.expect(rows[2].id == 1);
    try std.testing.expect(rows[3].id == 3);
}

test "ORDER BY nulls policy: FIRST/LAST" {
    const ally = std.testing.allocator;
    const ctx = planner.SessionContext{ .session_offset_minutes = 0 };
    var rows: [5]Row = .{
        .{
            .id = 0,
            .key = .{.Null},
        },
        .{ .id = 1, .key = .{ .DateTime = .{ .raw = "2024-01-01T10:00Z", .parsed = try @import("temporal.zig").parseDateTime("2024-01-01T10:00Z", true) } } },
        .{
            .id = 2,
            .key = .{.Null},
        },
        .{ .id = 3, .key = .{ .DateTime = .{ .raw = "2024-01-01T09:00Z", .parsed = try @import("temporal.zig").parseDateTime("2024-01-01T09:00Z", true) } } },
        .{ .id = 4, .key = .{ .DateTime = .{ .raw = "2024-01-01T11:00+01:00", .parsed = try @import("temporal.zig").parseDateTime("2024-01-01T11:00+01:00", true) } } },
    };
    // ASC NULLS FIRST: nulls should be at the start
    try stableOrderByTemporal(&rows, false, .first, ctx, ally);
    try std.testing.expect(rows[0].id == 0);
    try std.testing.expect(rows[1].id == 2);
    // ASC NULLS LAST: nulls should be at the end
    var rows2 = rows;
    try stableOrderByTemporal(&rows2, false, .last, ctx, ally);
    try std.testing.expect(rows2[3].id == 0);
    try std.testing.expect(rows2[4].id == 2);
    // DESC NULLS FIRST: nulls should be at the start
    var rows3 = rows;
    try stableOrderByTemporal(&rows3, true, .first, ctx, ally);
    try std.testing.expect(rows3[0].id == 0);
    try std.testing.expect(rows3[1].id == 2);
    // DESC NULLS LAST: nulls should be at the end
    var rows4 = rows;
    try stableOrderByTemporal(&rows4, true, .last, ctx, ally);
    try std.testing.expect(rows4[3].id == 0);
    try std.testing.expect(rows4[4].id == 2);
}

// Skeleton set operations over integer rows for semantics tests
pub fn dedupInts(ally: std.mem.Allocator, vals: []const i64) ![]i64 {
    var set = std.AutoHashMap(i64, void).init(ally);
    defer set.deinit();
    for (vals) |v| _ = try set.put(v, {});
    var out = try ally.alloc(i64, set.count());
    var it = set.keyIterator();
    var i: usize = 0;
    while (it.next()) |p| : (i += 1) out[i] = p.*;
    std.sort.block(i64, out, {}, std.sort.asc(i64));
    return out;
}

pub fn multisetIntersect(ally: std.mem.Allocator, a: []const i64, b: []const i64) ![]i64 {
    var map = std.AutoHashMap(i64, usize).init(ally);
    defer map.deinit();
    for (a) |v| {
        const cur = map.get(v) orelse 0;
        _ = try map.put(v, cur + 1);
    }
    var out = std.ArrayList(i64).init(ally);
    defer out.deinit();
    for (b) |v| if (map.get(v)) |cnt| if (cnt > 0) {
        try out.append(v);
        _ = try map.put(v, cnt - 1);
    };
    return out.toOwnedSlice();
}

pub fn multisetExcept(ally: std.mem.Allocator, a: []const i64, b: []const i64) ![]i64 {
    var map = std.AutoHashMap(i64, usize).init(ally);
    defer map.deinit();
    for (b) |v| {
        const cur = map.get(v) orelse 0;
        _ = try map.put(v, cur + 1);
    }
    var out = std.ArrayList(i64).init(ally);
    defer out.deinit();
    for (a) |v| {
        const cnt = map.get(v) orelse 0;
        if (cnt == 0) {
            try out.append(v);
        } else {
            _ = try map.put(v, cnt - 1);
        }
    }
    return out.toOwnedSlice();
}

test "set ops semantics: UNION DISTINCT and INTERSECT/EXCEPT ALL" {
    const A = [_]i64{ 1, 2, 2, 3 };
    const B = [_]i64{ 2, 3, 4 };
    // UNION DISTINCT
    var union_all = std.ArrayList(i64).init(std.testing.allocator);
    defer union_all.deinit();
    try union_all.appendSlice(&A);
    try union_all.appendSlice(&B);
    const union_distinct = try dedupInts(std.testing.allocator, union_all.items);
    defer std.testing.allocator.free(union_distinct);
    try std.testing.expectEqualSlices(i64, &[_]i64{ 1, 2, 3, 4 }, union_distinct);
    // INTERSECT ALL => multiplicity = min(countA, countB)
    const ia = try multisetIntersect(std.testing.allocator, &A, &B);
    defer std.testing.allocator.free(ia);
    // A has {1:1,2:2,3:1}; B has {2:1,3:1,4:1} => intersection ALL = {2,3}
    try std.testing.expect(ia.len == 2);
    // EXCEPT ALL => subtract multiplicities
    const ea = try multisetExcept(std.testing.allocator, &A, &B);
    defer std.testing.allocator.free(ea);
    // A \ B = {1,2}
    try std.testing.expect(ea.len == 2);
}

// ===========================
// Binding-table set operations
// ===========================

pub const BindingValue = union(enum) {
    Null,
    Int: i64,
    Str: []const u8,
    Bool: bool,
};

pub const BindingRow = struct {
    cols: []const BindingValue,
};

pub const OrderPolicy = enum { Sorted, StableLeft };

fn valueOrder(a: BindingValue, b: BindingValue) std.math.Order {
    // Null < Bool < Int < Str; within types, natural order. NULLs compare equal for set ops equality.
    const rank = struct {
        fn of(v: BindingValue) u8 {
            return switch (v) {
                .Null => 0,
                .Bool => 1,
                .Int => 2,
                .Str => 3,
            };
        }
    };
    const ra = rank.of(a);
    const rb = rank.of(b);
    if (ra < rb) return .lt;
    if (ra > rb) return .gt;
    // Same type, compare within
    return switch (a) {
        .Null => .eq,
        .Bool => |av| blk: {
            const bv = b.Bool;
            if (av == bv) break :blk .eq;
            break :blk if (av) .gt else .lt;
        },
        .Int => |av| blk2: {
            const bv = b.Int;
            if (av == bv) break :blk2 .eq;
            break :blk2 if (av < bv) .lt else .gt;
        },
        .Str => |as| std.mem.order(u8, as, b.Str),
    };
}

fn rowLess(a: []const BindingValue, b: []const BindingValue) bool {
    var i: usize = 0;
    const n = @min(a.len, b.len);
    while (i < n) : (i += 1) {
        const ord = valueOrder(a[i], b[i]);
        if (ord == .lt) return true;
        if (ord == .gt) return false;
    }
    return a.len < b.len;
}

fn valueEq(a: BindingValue, b: BindingValue) bool {
    switch (a) {
        .Null => return b == .Null,
        .Int => |ai| return b == .Int and ai == b.Int,
        .Str => |as| return b == .Str and std.mem.eql(u8, as, b.Str),
        .Bool => |ab| return b == .Bool and ab == b.Bool,
    }
}

fn rowEq(a: []const BindingValue, b: []const BindingValue) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) if (!valueEq(a[i], b[i])) return false;
    return true;
}

fn encodeValueKey(buf: *std.ArrayList(u8), v: BindingValue) !void {
    // Simple, deterministic encoding: type tag + length + payload; NULL is just tag.
    switch (v) {
        .Null => try buf.append('N'),
        .Bool => |b| {
            try buf.append('B');
            try buf.append(if (b) '1' else '0');
        },
        .Int => |n| {
            try buf.append('I');
            try buf.writer().print("{d};", .{n});
        },
        .Str => |s| {
            try buf.append('S');
            try buf.writer().print("{d}:", .{s.len});
            try buf.appendSlice(s);
        },
    }
}

fn rowKeyAlloc(ally: std.mem.Allocator, row: []const BindingValue) ![]u8 {
    var buf = std.ArrayList(u8).init(ally);
    errdefer buf.deinit();
    for (row, 0..) |v, i| {
        if (i > 0) try buf.append('|');
        try encodeValueKey(&buf, v);
    }
    return buf.toOwnedSlice();
}

fn sortUniqueRows(ally: std.mem.Allocator, rows: []const []BindingValue) ![]const []BindingValue {
    // Make a copy of slice-of-slices and sort lexicographically; then unique adjacent equals.
    const tmp = try ally.alloc([]const BindingValue, rows.len);
    errdefer ally.free(tmp);
    std.mem.copy([]const BindingValue, tmp, rows);
    std.sort.block([]const BindingValue, tmp, {}, struct {
        fn less(_: void, a: []const BindingValue, b: []const BindingValue) bool {
            return rowLess(a, b);
        }
    }.less);
    if (tmp.len == 0) return tmp;
    var out = std.ArrayList([]const BindingValue).init(ally);
    defer out.deinit();
    var i: usize = 0;
    while (i < tmp.len) : (i += 1) {
        if (out.items.len == 0 or !rowEq(out.items[out.items.len - 1], tmp[i])) {
            try out.append(tmp[i]);
        }
    }
    return out.toOwnedSlice();
}

pub fn unionDistinctRows(ally: std.mem.Allocator, a: []const []BindingValue, b: []const []BindingValue) ![]const []BindingValue {
    var all = std.ArrayList([]const BindingValue).init(ally);
    defer all.deinit();
    try all.appendSlice(a);
    try all.appendSlice(b);
    return try sortUniqueRows(ally, all.items);
}

pub fn unionAllRows(ally: std.mem.Allocator, a: []const []BindingValue, b: []const []BindingValue) ![]const []BindingValue {
    var out = std.ArrayList([]const BindingValue).init(ally);
    defer out.deinit();
    try out.appendSlice(a);
    try out.appendSlice(b);
    return out.toOwnedSlice();
}

pub fn intersectAllRows(ally: std.mem.Allocator, a: []const []BindingValue, b: []const []BindingValue) ![]const []BindingValue {
    // Stable-left: walk A, but limit multiplicity by counts in B
    var counts = std.StringHashMap(usize).init(ally);
    defer counts.deinit();
    for (b) |row| {
        const key = try rowKeyAlloc(ally, row);
        defer ally.free(key);
        const cur = counts.get(key) orelse 0;
        try counts.put(key, cur + 1);
    }
    var out = std.ArrayList([]const BindingValue).init(ally);
    defer out.deinit();
    for (a) |row| {
        const key = try rowKeyAlloc(ally, row);
        defer ally.free(key);
        if (counts.get(key)) |cnt| {
            if (cnt > 0) {
                try out.append(row);
                try counts.put(key, cnt - 1);
            }
        }
    }
    return out.toOwnedSlice();
}

pub fn intersectDistinctRows(ally: std.mem.Allocator, a: []const []BindingValue, b: []const []BindingValue) ![]const []BindingValue {
    var setA = std.StringHashMap(void).init(ally);
    defer setA.deinit();
    for (a) |row| {
        const key = try rowKeyAlloc(ally, row);
        defer ally.free(key);
        _ = try setA.put(key, {});
    }
    var uniq = std.ArrayList([]const BindingValue).init(ally);
    defer uniq.deinit();
    var seen = std.StringHashMap(void).init(ally);
    defer seen.deinit();
    for (b) |row| {
        const key = try rowKeyAlloc(ally, row);
        defer ally.free(key);
        if (setA.contains(key) and !seen.contains(key)) {
            _ = try seen.put(key, {});
            try uniq.append(row);
        }
    }
    // Sort for deterministic order
    return try sortUniqueRows(ally, uniq.items);
}

pub fn exceptAllRows(ally: std.mem.Allocator, a: []const []BindingValue, b: []const []BindingValue) ![]const []BindingValue {
    // Stable-left: emit rows from A after subtracting multiplicities found in B
    var counts = std.StringHashMap(usize).init(ally);
    defer counts.deinit();
    for (b) |row| {
        const key = try rowKeyAlloc(ally, row);
        defer ally.free(key);
        const cur = counts.get(key) orelse 0;
        try counts.put(key, cur + 1);
    }
    var out = std.ArrayList([]const BindingValue).init(ally);
    defer out.deinit();
    for (a) |row| {
        const key = try rowKeyAlloc(ally, row);
        defer ally.free(key);
        if (counts.get(key)) |cnt| {
            if (cnt == 0) {
                try out.append(row);
            } else {
                try counts.put(key, cnt - 1);
            }
        } else {
            try out.append(row);
        }
    }
    return out.toOwnedSlice();
}

pub fn exceptDistinctRows(ally: std.mem.Allocator, a: []const []BindingValue, b: []const []BindingValue) ![]const []BindingValue {
    var setB = std.StringHashMap(void).init(ally);
    defer setB.deinit();
    for (b) |row| {
        const key = try rowKeyAlloc(ally, row);
        defer ally.free(key);
        _ = try setB.put(key, {});
    }
    var uniq = std.ArrayList([]const BindingValue).init(ally);
    defer uniq.deinit();
    var seen = std.StringHashMap(void).init(ally);
    defer seen.deinit();
    for (a) |row| {
        const key = try rowKeyAlloc(ally, row);
        defer ally.free(key);
        if (!setB.contains(key) and !seen.contains(key)) {
            _ = try seen.put(key, {});
            try uniq.append(row);
        }
    }
    return try sortUniqueRows(ally, uniq.items);
}

test "binding table set ops: multi-column with NULLs" {
    const A0 = [_]BindingValue{ .{ .Int = 1 }, .{ .Str = "a" } };
    const A1 = [_]BindingValue{ .{.Null}, .{ .Str = "x" } };
    const A2 = [_]BindingValue{ .{ .Int = 1 }, .{ .Str = "a" } };
    const B0 = [_]BindingValue{ .{ .Int = 1 }, .{ .Str = "a" } };
    const B1 = [_]BindingValue{ .{.Null}, .{ .Str = "x" } };
    const B2 = [_]BindingValue{ .{.Null}, .{ .Str = "x" } };
    const A: []const []BindingValue = &.{ A0[0..], A1[0..], A2[0..] };
    const B: []const []BindingValue = &.{ B0[0..], B1[0..], B2[0..] };
    const ally = std.testing.allocator;
    const uD = try unionDistinctRows(ally, A, B);
    defer ally.free(uD);
    try std.testing.expect(uD.len == 2);
    const iA = try intersectAllRows(ally, A, B);
    defer ally.free(iA);
    // Counts: A has (1,"a"):2, (null,"x"):1; B has (1,"a"):1, (null,"x"):2 → min multiplicities ⇒ 1 copy of each
    try std.testing.expect(iA.len == 2);
    const eD = try exceptDistinctRows(ally, A, B);
    defer ally.free(eD);
    // Distinct A minus B => none (all A rows appear in B)
    try std.testing.expect(eD.len == 0);
    const eA = try exceptAllRows(ally, A, B);
    defer ally.free(eA);
    // All: (1,"a"): 2-1 = 1 left; (null,"x"): 1-2 = 0 left ⇒ total 1
    try std.testing.expect(eA.len == 1);
}
