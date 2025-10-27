const std = @import("std");
const Parser = @import("src/gql/parser.zig").Parser;
const Lexer = @import("src/gql/lexer.zig").Lexer;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const test_queries = [_][]const u8{
        // Working cases
        "MATCH path = (a)-[:KNOWS]->(b) RETURN path",
        "MATCH path = (a)-[*2..4]->(b) RETURN path",

        // Failing case
        "MATCH path = (a:Person)-[:KNOWS*2..4]->(b:Person) RETURN a.name, b.name, length(path)",

        // Variations to test
        "MATCH path = (a:Person)-[:KNOWS]->(b:Person) RETURN path",
        "MATCH path = (a)-[:KNOWS*2..4]->(b) RETURN path",
        "MATCH (a:Person)-[:KNOWS*2..4]->(b:Person) RETURN a.name, b.name",
    };

    std.debug.print("\n🔍 Path Variable Assignment Debug\n", .{});
    std.debug.print("==================================\n\n", .{});

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
