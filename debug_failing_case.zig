const std = @import("std");
const Parser = @import("src/gql/parser.zig").Parser;
const Lexer = @import("src/gql/lexer.zig").Lexer;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    const test_queries = [_][]const u8{
        // Break down the failing case step by step
        "MATCH path = (a:Person)-[:KNOWS*2..4]->(b:Person) RETURN a.name",
        "MATCH path = (a:Person)-[:KNOWS*2..4]->(b:Person) RETURN a.name, b.name",
        "MATCH path = (a:Person)-[:KNOWS*2..4]->(b:Person) RETURN length(path)",
        "MATCH path = (a:Person)-[:KNOWS*2..4]->(b:Person) RETURN a.name, length(path)",
        "MATCH path = (a:Person)-[:KNOWS*2..4]->(b:Person) RETURN a.name, b.name, length(path)",
        
        // Try with different variable name
        "MATCH p = (a:Person)-[:KNOWS*2..4]->(b:Person) RETURN a.name, b.name, length(p)",
    };
    
    std.debug.print("\n🔍 Failing Case Breakdown\n", .{});
    std.debug.print("==========================\n\n", .{});
    
    for (test_queries) |query| {
        std.debug.print("Testing: {s}\n", .{query});
        
        var l = Lexer{ .src = query };
        var p = Parser{ .lx = &l, .arena = &arena, .cur = l.next() };
        
        const result = p.parseProgram() catch |err| {
            std.debug.print("  ❌ ERROR: {}\n", .{err});
            if (p.last_error) |msg| {
                std.debug.print("     Message: {s}\n", .{msg});
            }
            std.debug.print("\n", .{});
            continue;
        };
        
        std.debug.print("  ✅ SUCCESS: Parsed {} statement(s)\n", .{result.statements.len});
        std.debug.print("\n", .{});
    }
}