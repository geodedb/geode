const std = @import("std");
const Parser = @import("src/gql/parser.zig").Parser;
const Lexer = @import("src/gql/lexer.zig").Lexer;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const test_queries = [_][]const u8{
        // Test exact failing cases from feature test
        "MATCH (n) RETURN COUNT(n) AS count",
        "MATCH (n) RETURN SUM(n.value) AS sum",

        // Test with different alias names
        "MATCH (n) RETURN COUNT(n) AS cnt",
        "MATCH (n) RETURN COUNT(n) AS my_count",

        // Test without alias
        "MATCH (n) RETURN COUNT(n)",
        "MATCH (n) RETURN SUM(n.value)",
    };

    std.debug.print("\n🔍 COUNT Alias Debug\n", .{});
    std.debug.print("====================\n\n", .{});

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
