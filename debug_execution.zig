const std = @import("std");
const Lexer = @import("src/gql/lexer.zig").Lexer;
const Parser = @import("src/gql/parser.zig").Parser;
const eval = @import("src/eval.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    std.debug.print("Testing double quote execution...\n", .{});
    
    // Test the exact same query that hangs
    const source = "RETURN \"test\"";
    std.debug.print("Testing: {s}\n", .{source});
    
    var lx = Lexer{ .src = source };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    
    std.debug.print("Parsing...\n", .{});
    const prog = p.parseProgram() catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        return;
    };
    
    std.debug.print("Parse successful! Statements: {}\n", .{prog.statements.len});
    
    if (prog.statements.len > 0) {
        const stmt = prog.statements[0];
        std.debug.print("Statement type: {}\n", .{stmt});
        
        if (stmt == .Query) {
            const query = stmt.Query;
            std.debug.print("Query has {} return items\n", .{query.ret.items.len});
            
            if (query.ret.items.len > 0) {
                const ret_item = query.ret.items[0];
                std.debug.print("Return item expr type: {}\n", .{ret_item.expr});
                
                // Try evaluating the expression
                std.debug.print("Evaluating expression...\n", .{});
                const env = eval.Env{ .names = &.{}, .values = &.{} };
                const result = eval.evalExpr(arena.allocator(), ret_item.expr, env) catch |err| {
                    std.debug.print("Eval error: {}\n", .{err});
                    return;
                };
                
                std.debug.print("Evaluation successful! Result: {}\n", .{result});
            }
        }
    }
}