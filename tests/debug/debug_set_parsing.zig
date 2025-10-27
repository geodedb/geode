const std = @import("std");
const Parser = @import("src/gql/parser.zig").Parser;
const Lexer = @import("src/gql/lexer.zig").Lexer;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const test_queries = [_][]const u8{
        "MATCH (a)-[*]->(b) RETURN a, b",
        "MATCH (a)-[*1..3]->(b) RETURN a, b",
        "MATCH (a)-[*..5]->(b) RETURN a, b",
        "MATCH (a)-[*2..]->(b) RETURN a, b",
        "MATCH SHORTEST (a)-[*]->(b) RETURN a, b",
        "MATCH ANY SHORTEST (a)-[*]->(b) RETURN a, b",
        "MATCH ALL SHORTEST (a)-[*]->(b) RETURN a, b",
        "MATCH WALK (a)-[*]->(b) RETURN a, b",
        "MATCH TRAIL (a)-[*]->(b) RETURN a, b",
        "MATCH ACYCLIC (a)-[*]->(b) RETURN a, b",
        "MATCH SIMPLE (a)-[*]->(b) RETURN a, b",
    };

    for (test_queries) |query| {
        std.debug.print("\nTesting: {s}\n", .{query});

        var l = Lexer{ .src = query };
        var p = Parser{ .lx = &l, .arena = &arena, .cur = l.next() };

        const result = p.parseProgram() catch |err| {
            std.debug.print("  ERROR: {}\n", .{err});
            if (p.last_error) |msg| {
                std.debug.print("  Message: {s}\n", .{msg});
            }
            continue;
        };

        std.debug.print("  SUCCESS: Parsed {} statement(s)\n", .{result.statements.len});
    }
}
