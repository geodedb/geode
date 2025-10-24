const std = @import("std");
const Parser = @import("src/gql/parser.zig").Parser;
const Lexer = @import("src/gql/lexer.zig").Lexer;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    const test_queries = [_][]const u8{
        // Test variable-length relationships with different path variable names
        "MATCH p = (a:Person)-[:KNOWS*2..4]->(b:Person) RETURN p",
        "MATCH mypath = (a:Person)-[:KNOWS*2..4]->(b:Person) RETURN mypath",
        
        // Test with path keyword but simpler relationship
        "MATCH path = (a:Person)-[:KNOWS]->(b:Person) RETURN path",
        
        // Test variable-length without path variable
        "MATCH (a:Person)-[:KNOWS*2..4]->(b:Person) RETURN a.name, b.name",
        
        // Test the exact failing case step by step
        "MATCH path = (a:Person)-[:KNOWS*2..4]->(b:Person) RETURN a.name",
    };
    
    std.debug.print("\n🔍 Variable Length Relationship Test\n", .{});
    std.debug.print("=====================================\n\n", .{});
    
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