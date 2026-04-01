const std = @import("std");
const Lexer = @import("src/gql/lexer.zig").Lexer;
const TokenKind = @import("gql_lib").token.TokenKind;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Test simple RETURN with string
    const source = "RETURN \"hello\" AS greeting";
    var lexer = Lexer{ .src = source };

    std.debug.print("Testing simple string query: {s}\n", .{source});

    var i: u32 = 0;
    while (i < 10) : (i += 1) { // safety limit
        const token = lexer.next();
        std.debug.print("Token {}: kind={}, lexeme='{s}'\n", .{ i, token.kind, token.lexeme });

        if (token.kind == .eof) break;
        if (token.kind == .invalid) {
            std.debug.print("Invalid token encountered!\n", .{});
            break;
        }
    }
}
