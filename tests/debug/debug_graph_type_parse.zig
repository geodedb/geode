const std = @import("std");
const geode = @import("src/root.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const query = "CREATE GRAPH TYPE test_type AS { }";
    std.log.info("Testing query: {s}", .{query});

    var lexer = geode.gql.Lexer.init(query);

    // Tokenize and print all tokens
    std.log.info("=== TOKENS ===");
    var count: u32 = 0;
    while (true) {
        const token = lexer.nextToken();
        count += 1;
        std.log.info("Token {}: kind={any}, lexeme='{s}'", .{ count, token.kind, token.lexeme });
        if (token.kind == .eof) break;
    }

    // Reset lexer and try parsing
    std.log.info("=== PARSING ===");
    lexer = geode.gql.Lexer.init(query);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = geode.gql.Parser.init(&lexer, &arena);
    const program = parser.parseProgram() catch |err| {
        std.log.err("Parse error: {}", .{err});
        return;
    };

    std.log.info("Parse successful! Statements: {}", .{program.statements.len});
    if (program.statements.len > 0) {
        std.log.info("Statement type: {any}", .{program.statements[0]});
    }
}
