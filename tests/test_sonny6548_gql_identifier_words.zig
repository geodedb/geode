//! SONNY-6548 reproductions, fixed by SONNY-6564 (the full regression is
//! tests/test_sonny6564_identifier_words.zig):
//! the parser applies ISO/IEC 39075:2024 21.3's identifier rule backwards.
//! 21.3 lists the <reserved word>s (COUNT, MATCH, PATH, RETURN, ...) and
//! the <non-reserved word>s (TYPE, PROPERTY, NODE, EDGE, ...); its Syntax
//! Rules say a non-delimited identifier "shall not be equal" to a reserved
//! word, so a non-reserved word is a valid variable and a reserved word is
//! not.
//!
//! 1. SET and REMOVE refuse a variable named with a non-reserved word that
//!    MATCH binds and RETURN reads: parseSetClause and parseRemoveClause
//!    (src/gql/parser.zig) require the target token to be `.identifier`
//!    (`if (self.cur.kind != .identifier) return error.UnexpectedToken;`),
//!    and TYPE and PROPERTY lex as keywords. `MATCH (type:T) SET type.x = 1`
//!    is answered 42000 "parse error".
//! 2. A reserved word is accepted as a variable: `MATCH (match:X) RETURN
//!    match` and `MATCH (return:X) RETURN return` succeed, and `RETURN MATCH`
//!    parses (it fails later, "Variable not in scope"). docs/GQL_COMPLIANCE.md
//!    ("Error Handling") lists `RETURN MATCH` as a syntax error.
//!
//! Moved from tests/gql_keyword_regression_test.zig (its `count` cases were
//! dropped: COUNT is reserved) and tests/gql_compliance_regression_test.zig.
const std = @import("std");
const geode = @import("geode");
const Parser = geode.gql.parser.Parser;
const Lexer = geode.gql.lexer.Lexer;

fn parses(arena: *std.heap.ArenaAllocator, query: []const u8) bool {
    var l = Lexer{ .src = query };
    var p = Parser{ .lx = &l, .arena = arena, .cur = l.next() };
    const program = p.parseProgram() catch |err| {
        std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
        return false;
    };
    return program.statements.len == 1;
}

test "SONNY-6548: a non-reserved word names a variable in MATCH and RETURN (control)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "MATCH (type:TypeInfo) RETURN type.temporary",
        "MATCH (property:Metadata) RETURN property",
    }) |q| try std.testing.expect(parses(&arena, q));
}

test "SONNY-6548: SET and REMOVE accept a variable named with a non-reserved word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failed: usize = 0;
    for ([_][]const u8{
        "MATCH (type:TypeInfo) SET type.x = 1",
        "MATCH (type:TypeInfo) REMOVE type.temporary",
        "MATCH (property:Metadata) SET property.x = 1",
        "MATCH (property:Metadata) REMOVE property:Old",
        "MATCH p = (c:Counter)-[:HAS_TYPE]->(type:TypeInfo) SET type.property = 1",
    }) |q| {
        if (!parses(&arena, q)) failed += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "SONNY-6548: a reserved word is not accepted as a variable (ISO/IEC 39075 21.3)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var accepted: usize = 0;
    for ([_][]const u8{
        "RETURN MATCH",
        "MATCH (match:X) RETURN match",
        "MATCH (return:X) RETURN return",
    }) |q| {
        var l = Lexer{ .src = q };
        var p = Parser{ .lx = &l, .arena = &arena, .cur = l.next() };
        if (p.parseProgram()) |_| {
            std.debug.print("accepted: {s}\n", .{q});
            accepted += 1;
        } else |_| {}
    }
    try std.testing.expectEqual(@as(usize, 0), accepted);
}
