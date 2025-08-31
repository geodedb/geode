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
            const cmp = planner.compareTemporalForOrder(ra.key, rb.key, sc.ctx) catch |e| {
                // Fallback to lexicographic stringify on error.Invalid
                _ = e;
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
    std.mem.copy(Row, rows, tmp);
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
