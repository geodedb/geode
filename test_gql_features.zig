const std = @import("std");
const Parser = @import("src/gql/parser.zig").Parser;
const Lexer = @import("src/gql/lexer.zig").Lexer;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    const test_queries = [_][]const u8{
        // String concatenation
        "RETURN 'hello' || ' world' AS concatenated",
        
        // Aggregation functions
        "MATCH (n) RETURN COUNT(n) AS count",
        "MATCH (n) RETURN SUM(n.value) AS sum",
        "MATCH (n) RETURN AVG(n.score) AS average",
        "MATCH (n) RETURN MIN(n.age) AS minimum",
        "MATCH (n) RETURN MAX(n.age) AS maximum",
        
        // SET/REMOVE without RETURN
        "MATCH (n) SET n.property = 'value'",
        "MATCH (n) REMOVE n.property",
        
        // DETACH DELETE
        "MATCH (n) DETACH DELETE n",
        
        // Built-in functions
        "RETURN upper('hello') AS upper_case",
        "RETURN lower('WORLD') AS lower_case",
        "RETURN length('test') AS string_length",
        "RETURN abs(-5) AS absolute",
        "RETURN sqrt(16) AS square_root",
        
        // Variable-length paths
        "MATCH (a)-[*1..3]->(b) RETURN a, b",
        "MATCH (a)-[*..5]->(b) RETURN a, b",
        "MATCH (a)-[*2..]->(b) RETURN a, b",
        
        // Session management
        "USE GRAPH social_network",
        "SET SESSION GRAPH = 'production'",
        
        // Transactions
        "START TRANSACTION",
        "COMMIT",
        "ROLLBACK",
        
        // MERGE operations
        "MERGE (n:Person {id: 1}) ON CREATE SET n.created = now() ON MATCH SET n.accessed = now()",
    };
    
    var passed: u32 = 0;
    var failed: u32 = 0;
    
    std.debug.print("\n🔍 GQL Compliance Feature Test\n", .{});
    std.debug.print("==============================\n\n", .{});
    
    for (test_queries) |query| {
        std.debug.print("Testing: {s}\n", .{query});
        
        var l = Lexer{ .src = query };
        var p = Parser{ .lx = &l, .arena = &arena, .cur = l.next() };
        
        const result = p.parseProgram() catch |err| {
            std.debug.print("  ❌ ERROR: {}\n", .{err});
            if (p.last_error) |msg| {
                std.debug.print("     Message: {s}\n", .{msg});
            }
            failed += 1;
            std.debug.print("\n", .{});
            continue;
        };
        
        std.debug.print("  ✅ SUCCESS: Parsed {} statement(s)\n", .{result.statements.len});
        passed += 1;
        std.debug.print("\n", .{});
    }
    
    std.debug.print("==============================\n", .{});
    std.debug.print("FEATURE TEST SUMMARY\n", .{});
    std.debug.print("==============================\n", .{});
    std.debug.print("✅ Passed: {}\n", .{passed});
    std.debug.print("❌ Failed: {}\n", .{failed});
    std.debug.print("📊 Total:  {}\n", .{passed + failed});
    
    const success_rate = (@as(f64, @floatFromInt(passed)) / @as(f64, @floatFromInt(passed + failed))) * 100.0;
    std.debug.print("📈 Success Rate: {d:.1}%\n\n", .{success_rate});
    
    if (success_rate >= 95.0) {
        std.debug.print("🟢 EXCELLENT COMPLIANCE (>95%)\n", .{});
        std.debug.print("Geode successfully parses most GQL features\n", .{});
    } else if (success_rate >= 80.0) {
        std.debug.print("🟡 GOOD COMPLIANCE (>80%)\n", .{});
        std.debug.print("Geode implements most core GQL features\n", .{});
    } else {
        std.debug.print("🔴 NEEDS IMPROVEMENT (<80%)\n", .{});
        std.debug.print("Several GQL features need implementation\n", .{});
    }
}