const std = @import("std");
const geode = @import("lib.zig");
const eval = geode.eval;
const ast = geode.ast;

// Direct eval unit test ensures guard returns TypeMismatch instead of panic.

fn bin(op: ast.BinOp, l: i64, r: i64) !eval.Value {
    const env = eval.Env{ .names = &.{}, .values = &.{} };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const L = ast.Expr{ .Int = l };
    const R = ast.Expr{ .Int = r };
    const expr = ast.Expr{ .Binary = .{ .op = op, .lhs = &L, .rhs = &R } };
    return eval.evalExpr(arena.allocator(), expr, env);
}

test "eval: division by zero returns TypeMismatch" {
    const res = bin(.Div, 1, 0) catch |e| {
        try std.testing.expectEqual(error.TypeMismatch, e);
        return; // success path via error
    };
    // Should not produce a value
    try std.testing.expect(false);
    _ = res;
}
