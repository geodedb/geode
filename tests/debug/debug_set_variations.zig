const std = @import("std");
const Parser = @import("src/gql/parser.zig").Parser;
const Lexer = @import("src/gql/lexer.zig").Lexer;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const test_queries = [_][]const u8{
        // Test variations with different node patterns
        "MATCH (n) SET n.x = 1",
        "MATCH (n:Label) SET n.x = 1",
        "MATCH (node) SET node.x = 1",
        "MATCH (person:Person) SET person.x = 1",

        // Test with different property names
        "MATCH (n) SET n.a = 1",
        "MATCH (n) SET n.test = 1",
        "MATCH (n) SET n.name = 'test'",

        // Test REMOVE variations
        "MATCH (n) REMOVE n.x",
        "MATCH (n:Label) REMOVE n.x",

        // Test with WHERE clause
        "MATCH (n) WHERE n.id = 1 SET n.x = 2",
        "MATCH (n:Person) WHERE n.age > 30 SET n.updated = true",
    };

    std.debug.print("\n🔍 SET/REMOVE Variations Debug\n", .{});
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
            std.debug.print("\n", .{});
            continue;
        };

        std.debug.print("  ✅ SUCCESS: Parsed {} statement(s)\n", .{result.statements.len});
        std.debug.print("\n", .{});
    }
}
