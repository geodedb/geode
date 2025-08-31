const std = @import("std");
const ast = @import("gql/ast.zig");
const planner = @import("planner.zig");
const printer = @import("gql/print.zig");

pub const Row = struct {
    // For this minimal harness, a single key expression (temporal literal) to sort by.
    key: ast.Expr,
    // An identifier to test stability.
    id: usize,
};

pub fn stableOrderByTemporal(rows: []Row, desc: bool, ctx: planner.SessionContext, ally: std.mem.Allocator) !void {
    // Sort indices to keep original stability; break ties by original index.
    var idxs = try ally.alloc(usize, rows.len);
    defer ally.free(idxs);
    for (idxs, 0..) |*p, i| p.* = i;
    const Ctx = struct {
        rows: []Row,
        desc: bool,
        ctx: planner.SessionContext,
    };
    const sctx = Ctx{ .rows = rows, .desc = desc, .ctx = ctx };
    std.sort.pdq(usize, idxs, sctx, struct {
        fn less(sc: Ctx, a: usize, b: usize) bool {
            const ra = sc.rows[a];
            const rb = sc.rows[b];
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
    try stableOrderByTemporal(&rows, false, ctx, ally);
    try std.testing.expect(rows[0].id == 2);
    // The next three can be in original relative order among equal keys due to stability: ids 0,1,3 should preserve input order 0,1,3.
    try std.testing.expect(rows[1].id == 0);
    try std.testing.expect(rows[2].id == 1);
    try std.testing.expect(rows[3].id == 3);
}
