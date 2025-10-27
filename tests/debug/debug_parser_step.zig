const std = @import("std");
const Parser = @import("src/gql/parser.zig").Parser;
const Lexer = @import("src/gql/lexer.zig").Lexer;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const query = "MATCH path = (a)-[:KNOWS]->(b) RETURN path";
    std.debug.print("Parsing: {s}\n\n", .{query});

    var l = Lexer{ .src = query };
    var p = Parser{ .lx = &l, .arena = &arena, .cur = l.next() };

    // Manually step through the parseQuery logic
    std.debug.print("Starting token: {} '{s}'\n", .{ p.cur.kind, p.cur.lexeme });

    // Should be MATCH
    if (p.cur.kind == .MATCH) {
        std.debug.print("Found MATCH token\n", .{});
        p.advance();
        std.debug.print("Next token: {} '{s}'\n", .{ p.cur.kind, p.cur.lexeme });

        // Should be PATH
        if (p.cur.kind == .PATH) {
            std.debug.print("Found PATH token\n", .{});
            std.debug.print("Peek kind: {}\n", .{p.peekKind()});

            if (p.peekKind() == .eq) {
                std.debug.print("Next token is =, should accept as path variable\n", .{});
            } else {
                std.debug.print("Next token is NOT =\n", .{});
            }
        } else {
            std.debug.print("Expected PATH but got {}\n", .{p.cur.kind});
        }
    }
}
