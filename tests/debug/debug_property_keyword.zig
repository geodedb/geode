const std = @import("std");
const Parser = @import("src/gql/parser.zig").Parser;
const Lexer = @import("src/gql/lexer.zig").Lexer;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const test_queries = [_][]const u8{
        // Test the exact failing queries from feature test
        "MATCH (n) SET n.property = 'value'",
        "MATCH (n) REMOVE n.property",

        // Test with different property names
        "MATCH (n) SET n.prop = 'value'",
        "MATCH (n) REMOVE n.prop",
        "MATCH (n) SET n.name = 'value'",
        "MATCH (n) REMOVE n.name",
    };

    std.debug.print("\n🔍 Property Keyword Debug\n", .{});
    std.debug.print("=========================\n\n", .{});

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
