const std = @import("std");
const Lexer = @import("src/gql/lexer.zig").Lexer;

pub fn main() !void {
    const query = "MATCH path = (a)-[:KNOWS]->(b) RETURN path";

    std.debug.print("Tokenizing: {s}\n\n", .{query});

    var l = Lexer{ .src = query };
    var count: u32 = 0;

    while (true) {
        const tok = l.next();
        count += 1;

        std.debug.print("{}: {} '{s}'\n", .{ count, tok.kind, tok.lexeme });

        if (tok.kind == .eof) break;
        if (count > 20) break; // Safety limit
    }
}
