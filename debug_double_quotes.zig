const std = @import("std");
const gql = @import("src/gql.zig");
const lexer_mod = @import("src/gql/lexer.zig");
const parser_mod = @import("src/gql/parser.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    std.debug.print("Testing double quote parsing...\n", .{});
    
    // Test 1: Simple double quote
    const source1 = "\"test\"";
    std.debug.print("Testing: {s}\n", .{source1});
    
    var lx1 = lexer_mod.Lexer{ .src = source1 };
    const token1 = lx1.next();
    std.debug.print("Token kind: {}, lexeme: '{s}'\n", .{ token1.kind, token1.lexeme });
    
    // Test 2: Double quote in expression
    const source2 = "RETURN \"hello\"";
    std.debug.print("Testing: {s}\n", .{source2});
    
    var lx2 = lexer_mod.Lexer{ .src = source2 };
    
    // Get tokens one by one
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const token = lx2.next();
        std.debug.print("Token {}: kind={}, lexeme='{s}'\n", .{ i, token.kind, token.lexeme });
        if (token.kind == .eof) break;
    }
    
    // Test 3: Try parsing the full expression
    std.debug.print("Testing full parse...\n", .{});
    var lx3 = lexer_mod.Lexer{ .src = source2 };
    var p = parser_mod.Parser{ .lx = &lx3, .arena = &arena, .cur = lx3.next() };
    
    std.debug.print("About to parse program...\n", .{});
    const prog = p.parseProgram() catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        return;
    };
    
    std.debug.print("Parse successful! Statements: {}\n", .{prog.statements.len});
}