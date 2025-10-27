const std = @import("std");
const eval = @import("src/eval.zig");
const ast = @import("src/gql/ast.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test evaluating a simple string expression
    const string_expr = ast.Expr{ .String = "hello" };
    std.debug.print("Testing string expression evaluation...\n", .{});

    const env = eval.Env{ .names = &.{}, .values = &.{} };

    const result = eval.evalExpr(allocator, string_expr, env) catch |err| {
        std.debug.print("Evaluation error: {}\n", .{err});
        return;
    };

    std.debug.print("Evaluation completed successfully!\n", .{});
    std.debug.print("Result: {}\n", .{result});
}
