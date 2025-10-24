const std = @import("std");
const exec = @import("exec.zig");
const ast = @import("gql/ast.zig");
const eval = @import("eval.zig");
const planner = @import("planner.zig");

// CANARY: REQ=REQ-GQL-012; FEATURE="GROUP BY/Aggregation"; ASPECT=HavingCountDistinctFilter; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_012_HavingCountDistinctFilter; OWNER=engine; UPDATED=2025-09-21

// Test that HAVING with COUNT(DISTINCT a) correctly filters groups and rewrites aggregate references.
// Scenario:
// Input rows (g,a): (X,1),(X,1),(X,2),(Y,1),(Y,1),(Y,1),(Z,null)
// Group by g. HAVING COUNT(DISTINCT a) > 1   => expect only group X (values {1,2}) passes; Y has 1 distinct, Z has 0.
// RETURN g, COUNT(DISTINCT a) AS c

test "TestCANARY_REQ_GQL_012_HavingCountDistinctFilter" {
    const allocator = std.testing.allocator;
    // Build AST for: SELECT g, COUNT(DISTINCT a) AS c FROM input GROUP BY g HAVING COUNT(DISTINCT a) > 1
    // In internal AST form: Query with group_by keys=[g], return items [g, countDistinct(a) AS c], having countDistinct(a) > 1
    const g_ident = ast.Expr{ .Ident = "g" };
    const a_ident = ast.Expr{ .Ident = "a" };
    const one_lit = ast.Expr{ .Int = 1 };
    const cd_call_inner = ast.Expr{ .Ident = "countDistinct" }; // produced by parser rewrite normally
    const arg_a = &a_ident;
    const call_cd = ast.Expr{ .Call = .{ .callee = &cd_call_inner, .args = &.{arg_a} } };
    const call_cd2 = ast.Expr{ .Call = .{ .callee = &cd_call_inner, .args = &.{arg_a} } };
    // having expression: countDistinct(a) > 1
    const gt_expr = ast.Expr{ .Binary = .{ .op = .gt, .left = &call_cd2, .right = &one_lit } };
    const ret_items = [_]ast.ReturnItem{
        .{ .expr = g_ident, .alias = null },
        .{ .expr = call_cd, .alias = "c" },
    };
    const q: ast.Query = .{
        .optional_match = false,
        .match = .{ .chains = &.{} },
        .where_clause = null,
        .with_clause = null,
        .group_by = .{ .keys = &.{g_ident} },
        .having = gt_expr,
        .ret = .{ .items = ret_items[0..], .distinct = false },
        .order_by = null,
        .limit = null,
        .offset = null,
    };

    // Input rows
    // (X,1),(X,1),(X,2),(Y,1),(Y,1),(Y,1),(Z,null)
    var rows_buf: [7][]eval.Value = .{
        &.{ .{ .Str = "X" }, .{ .Int = 1 } },
        &.{ .{ .Str = "X" }, .{ .Int = 1 } },
        &.{ .{ .Str = "X" }, .{ .Int = 2 } },
        &.{ .{ .Str = "Y" }, .{ .Int = 1 } },
        &.{ .{ .Str = "Y" }, .{ .Int = 1 } },
        &.{ .{ .Str = "Y" }, .{ .Int = 1 } },
        &.{ .{ .Str = "Z" }, .{ .Null = {} } },
    };
    const input_rows: []const []eval.Value = rows_buf[0..];
    const names = &.{ "g", "a" };

    // Validate plan (ensures legality checks pass)
    _ = try planner.planQuery(q, .{});

    const out = try exec.runGroupedQuery(allocator, q, names, input_rows, &.{}, &.{}, null);
    defer allocator.free(out);
    try std.testing.expect(out.len == 1);
    const r = out[0];
    // Expect columns: g, countDistinct(a)
    try std.testing.expect(r.len == 2);
    try std.testing.expect(r[0] == .Str and std.mem.eql(u8, r[0].Str, "X"));
    try std.testing.expect(r[1] == .Int and r[1].Int == 2);
}
