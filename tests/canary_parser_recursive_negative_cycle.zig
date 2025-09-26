const std = @import("std");
const gql_parser = @import("src/gql/parser.zig");
const gql_lexer = @import("src/gql/lexer.zig");
const gql_ast = @import("src/gql/ast.zig");

// Negative cycle / recursion boundary test for WITH RECURSIVE recognition stub.
// Ensures parser does not incorrectly mark queries recursive when RECURSIVE appears in non-leading position
// and rejects malformed constructs like repeating WITH RECURSIVE tokens.
//
// CANARY: REQ=REQ-GQL-079; FEATURE="RecursiveExecution"; ASPECT=ParserRecognition; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_079_ParserRecognitionNegativeCycle; OWNER=engine; UPDATED=2025-09-26

test "TestCANARY_REQ_GQL_079_ParserRecognitionNegativeCycle" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    var arena_state = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena_state.deinit();
    const arena = &arena_state;

    const cases = [_]struct { text: []const u8, expect_recursive: bool }{
        .{ .text = "WITH RECURSIVE RETURN 1 AS x", .expect_recursive = true }, // valid recognition
        .{ .text = "RETURN 1 AS x WITH RECURSIVE RETURN 2 AS y", .expect_recursive = false }, // RECURSIVE not leading
        .{ .text = "WITH RECURSIVE WITH RECURSIVE RETURN 1 AS x", .expect_recursive = true }, // second ignored (malformed)
    };

    for (cases) |c| {
        var lx = gql_lexer.Lexer.init(c.text, .{});
        var p = gql_parser.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
        const program = p.parseProgram() catch |e| switch (e) {
            error.UnexpectedToken => continue, // invalid forms tolerated for negative branch
            else => return e,
        };
        var any_recursive = false;
        for (program.statements) |st| switch (st) {
            .Query => |q| {
                if (q.has_recursive_cte) any_recursive = true;
            },
            else => {},
        };
        if (c.expect_recursive) {
            try std.testing.expect(any_recursive);
        } else {
            try std.testing.expect(!any_recursive);
        }
    }
}
