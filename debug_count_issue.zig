const std = @import("std");
const Parser = @import("src/gql/parser.zig").Parser;
const Lexer = @import("src/gql/lexer.zig").Lexer;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    const test_queries = [_][]const u8{
        // Test different COUNT variations
        "RETURN COUNT(*) AS count_all",
        "RETURN COUNT(n) AS count_n", 
        "RETURN COUNT(n.property) AS count_prop",
        
        // Test other aggregations
        "RETURN SUM(n.value) AS sum_value",
        "RETURN SUM(*) AS sum_all",
        "RETURN AVG(n.value) AS avg_value",
        "RETURN MIN(n.value) AS min_value",
        "RETURN MAX(n.value) AS max_value",
        
        // Test in MATCH context
        "MATCH (n) RETURN COUNT(*)",
        "MATCH (n) RETURN COUNT(n)",
        "MATCH (n) RETURN AVG(n.age)",
    };
    
    std.debug.print("\n🔍 COUNT and Aggregation Debug\n", .{});
    std.debug.print("===============================\n\n", .{});
    
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