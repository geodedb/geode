const std = @import("std");
const geode = @import("geode");

// Unit test: division by zero surfaces TypeMismatch (no panic) at evaluator boundary.
// Uses a minimal AST construction similar to parser output.

fn makeInt(n: i64) geode.ast.Expr {
    return .{ .Int = n };
}

fn makeDiv(a: *geode.ast.Expr, b: *geode.ast.Expr) geode.ast.Expr {
    return .{ .Binary = .{ .op = .Div, .lhs = a, .rhs = b } }; // adapt field names if ast differs
}

test "eval: division by zero returns error.TypeMismatch" {
    var lhs = makeInt(1);
    var rhs = makeInt(0);
    const div_expr = makeDiv(&lhs, &rhs);
    const env = geode.eval.Env{ .names = &.{}, .values = &.{} };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = geode.eval.evalExpr(arena.allocator(), div_expr, env) catch |e| {
        try std.testing.expectEqual(error.TypeMismatch, e);
        return; // success via error path
    };
    try std.testing.expect(false); // should not reach
}
