const std = @import("std");
const Parser = @import("src/gql/parser.zig").Parser;
const Lexer = @import("src/gql/lexer.zig").Lexer;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const test_queries = [_][]const u8{
        // Test SET/REMOVE with and without RETURN
        "MATCH (n) SET n.property = 'value'",
        "MATCH (n) REMOVE n.property",
        "MATCH (n) SET n.property = 'value' RETURN n",
        "MATCH (n) REMOVE n.property RETURN n",

        // Test more complex SET/REMOVE
        "MATCH (n:Person) SET n.age = 30, n.updated = now()",
        "MATCH (n:Person) REMOVE n.temp, n.old_field",

        // Test from GQL compliance test (should work)
        "MATCH (n) SET n.property = 'value' RETURN n.property",
        "MATCH (n) REMOVE n.property RETURN count(n)",
    };

    std.debug.print("\n🔍 SET/REMOVE Debug\n", .{});
    std.debug.print("===================\n\n", .{});

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
