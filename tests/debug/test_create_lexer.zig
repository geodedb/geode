const std = @import("std");
const lexer = @import("src/gql/lexer.zig");

pub fn main() !void {
    // Test CREATE with properties
    const query = "CREATE (n:Person {name: 'Alice', age: 30})";

    var l = lexer.Lexer{ .src = query };

    std.debug.print("Tokenizing: {s}\n", .{query});
    std.debug.print("Tokens:\n", .{});

    while (true) {
        const tok = l.next();
        std.debug.print("  {}: '{s}'\n", .{ tok.kind, tok.lexeme });
        if (tok.kind == .eof) break;
    }
}
