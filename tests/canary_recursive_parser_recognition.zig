const std = @import("std");
const gql_parser = @import("../src/gql/parser.zig");
const lexer = @import("../src/gql/lexer.zig");
const ast = @import("../src/gql/ast.zig");

// TestCANARY_REQ_GQL_079_ParserRecognition
// Ensures that a leading WITH RECURSIVE sets has_recursive_cte on the first Query statement
// and that absence of the prefix leaves the flag false.
test "TestCANARY_REQ_GQL_079_ParserRecognition" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    // Case 1: WITH RECURSIVE present
    const src1 = "WITH RECURSIVE MATCH (n) RETURN n";
    var lx1 = lexer.Lexer.init(src1);
    var p1 = gql_parser.Parser{
        .lx = &lx1,
        .arena = &arena,
        .cur = lx1.next(),
    };
    const prog1 = try p1.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), prog1.statements.len);
    switch (prog1.statements[0]) {
        .Query => |q| try std.testing.expect(q.has_recursive_cte),
        else => return error.UnexpectedStatementType,
    }

    // Case 2: No WITH RECURSIVE prefix
    const src2 = "MATCH (n) RETURN n";
    var lx2 = lexer.Lexer.init(src2);
    var p2 = gql_parser.Parser{
        .lx = &lx2,
        .arena = &arena,
        .cur = lx2.next(),
    };
    const prog2 = try p2.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), prog2.statements.len);
    switch (prog2.statements[0]) {
        .Query => |q| try std.testing.expect(!q.has_recursive_cte),
        else => return error.UnexpectedStatementType,
    }
}
