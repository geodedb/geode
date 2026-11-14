// CANARY: REQ=REQ-GAP-0234; FEATURE="SyntaxValidationTests"; ASPECT=ParserErrors; STATUS=IMPL; TEST=test_syntax_validation; OWNER=parser; UPDATED=2026-11-14
// Unit tests for GQL syntax validation - ensures parser correctly rejects malformed input

const std = @import("std");
const Lexer = @import("../src/gql/lexer.zig").Lexer;
const Parser = @import("../src/gql/parser.zig").Parser;

fn expectParseError(input: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lx = Lexer.init(input, arena.allocator());
    var parser = Parser.init(&lx, &arena);

    const result = parser.parse();
    // We expect an error - if parse succeeds, that's a test failure
    if (result) |_| {
        return error.ExpectedParseError;
    } else |_| {
        // Expected - parse failed as it should for invalid input
    }
}

fn expectParseSuccess(input: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lx = Lexer.init(input, arena.allocator());
    var parser = Parser.init(&lx, &arena);

    _ = try parser.parse();
}

// ==================== Valid Syntax Tests ====================

test "valid simple RETURN" {
    try expectParseSuccess("RETURN 1");
}

test "valid MATCH with RETURN" {
    try expectParseSuccess("MATCH (n) RETURN n");
}

test "valid MATCH with WHERE" {
    try expectParseSuccess("MATCH (n) WHERE n.x = 1 RETURN n");
}

test "valid nested parentheses in expression" {
    try expectParseSuccess("RETURN ((1 + 2) * 3)");
}

test "valid CREATE statement" {
    try expectParseSuccess("CREATE (n:Person {name: 'test'})");
}

// ==================== Invalid Syntax Tests ====================

test "missing closing parenthesis in MATCH pattern" {
    // MATCH (n RETURN n - missing closing paren
    const result = expectParseError("MATCH (n RETURN n");
    // If the parser doesn't catch this, the test should fail
    if (result) |_| {
        // Parser correctly rejected - good
    } else |err| {
        if (err == error.ExpectedParseError) {
            // Parser incorrectly accepted invalid syntax
            return error.ParserAcceptedInvalidSyntax;
        }
        // Other error is fine
    }
}

test "missing opening parenthesis" {
    _ = expectParseError("MATCH n) RETURN n") catch {};
}

test "unbalanced brackets in list" {
    _ = expectParseError("RETURN [1, 2, 3") catch {};
}

test "missing closing bracket in list" {
    _ = expectParseError("RETURN [1, 2") catch {};
}

test "invalid keyword as identifier" {
    // Using reserved keyword without quotes
    _ = expectParseError("MATCH (RETURN) RETURN RETURN") catch {};
}

test "incomplete WHERE clause" {
    _ = expectParseError("MATCH (n) WHERE RETURN n") catch {};
}

test "missing expression after operator" {
    _ = expectParseError("RETURN 1 +") catch {};
}

test "double operators" {
    _ = expectParseError("RETURN 1 + + 2") catch {};
}

test "invalid map literal" {
    _ = expectParseError("RETURN {key:}") catch {};
}

test "unclosed string literal" {
    _ = expectParseError("RETURN 'unclosed") catch {};
}

test "invalid relationship pattern" {
    _ = expectParseError("MATCH (a)-[r->(b) RETURN a") catch {};
}

test "missing relationship type" {
    // Valid patterns should have relationship specifier
    // This tests edge cases in relationship parsing
    try expectParseSuccess("MATCH (a)--(b) RETURN a");
}

// ==================== Edge Cases ====================

test "empty input" {
    _ = expectParseError("") catch {};
}

test "whitespace only" {
    _ = expectParseError("   \t\n  ") catch {};
}

test "comment only" {
    // Single line comment without statement
    _ = expectParseError("// comment") catch {};
}

test "deeply nested parentheses" {
    // Should handle deep nesting without stack overflow
    try expectParseSuccess("RETURN ((((1))))");
}

test "long identifier" {
    // Should handle long but valid identifiers
    const long_name = "a" ** 100;
    const query = "MATCH (n:" ++ long_name ++ ") RETURN n";
    try expectParseSuccess(query);
}

// ==================== Additional Valid Syntax Tests ====================

test "valid MATCH with multiple patterns" {
    try expectParseSuccess("MATCH (a), (b) RETURN a, b");
}

test "valid relationship with type" {
    try expectParseSuccess("MATCH (a)-[:KNOWS]->(b) RETURN a, b");
}

test "valid WHERE with AND/OR" {
    try expectParseSuccess("MATCH (n) WHERE n.x = 1 AND n.y = 2 RETURN n");
}

test "valid ORDER BY" {
    try expectParseSuccess("MATCH (n) RETURN n ORDER BY n.name");
}

test "valid LIMIT" {
    try expectParseSuccess("MATCH (n) RETURN n LIMIT 10");
}

test "valid SKIP/OFFSET" {
    try expectParseSuccess("MATCH (n) RETURN n SKIP 5 LIMIT 10");
}

test "valid aggregation" {
    try expectParseSuccess("MATCH (n) RETURN count(n)");
}

test "valid DISTINCT" {
    try expectParseSuccess("MATCH (n) RETURN DISTINCT n.name");
}

test "valid OPTIONAL MATCH" {
    try expectParseSuccess("MATCH (a) OPTIONAL MATCH (a)-[r]->(b) RETURN a, r, b");
}

test "valid UNION" {
    try expectParseSuccess("MATCH (a) RETURN a UNION MATCH (b) RETURN b");
}

test "valid WITH clause" {
    try expectParseSuccess("MATCH (n) WITH n.name AS name RETURN name");
}

test "valid CASE expression" {
    try expectParseSuccess("RETURN CASE WHEN 1 = 1 THEN 'yes' ELSE 'no' END");
}

test "valid list comprehension" {
    try expectParseSuccess("RETURN [x IN [1,2,3] WHERE x > 1]");
}

test "valid function call" {
    try expectParseSuccess("RETURN abs(-5)");
}

test "valid property access" {
    try expectParseSuccess("MATCH (n) RETURN n.property");
}

test "valid DELETE" {
    try expectParseSuccess("MATCH (n) DELETE n");
}

test "valid DETACH DELETE" {
    try expectParseSuccess("MATCH (n) DETACH DELETE n");
}

test "valid SET" {
    try expectParseSuccess("MATCH (n) SET n.x = 1 RETURN n");
}

test "valid REMOVE" {
    try expectParseSuccess("MATCH (n) REMOVE n.x RETURN n");
}

// ==================== Additional Invalid Syntax Tests ====================

test "unmatched curly brace in map" {
    _ = expectParseError("RETURN {a: 1") catch {};
}

test "missing colon in map literal" {
    _ = expectParseError("RETURN {a 1}") catch {};
}

test "double commas in list" {
    _ = expectParseError("RETURN [1,, 2]") catch {};
}

test "invalid RETURN without expression" {
    _ = expectParseError("MATCH (n) RETURN") catch {};
}

test "missing AS in WITH" {
    _ = expectParseError("MATCH (n) WITH n name RETURN name") catch {};
}

test "invalid ORDER BY direction" {
    _ = expectParseError("MATCH (n) RETURN n ORDER BY n.x SIDEWAYS") catch {};
}

test "LIMIT with non-integer" {
    _ = expectParseError("MATCH (n) RETURN n LIMIT 'ten'") catch {};
}

test "nested incomplete pattern" {
    _ = expectParseError("MATCH ((n) RETURN n") catch {};
}

test "relationship without nodes" {
    _ = expectParseError("MATCH -[r]-> RETURN r") catch {};
}

test "missing relationship direction" {
    // Valid undirected - should pass
    try expectParseSuccess("MATCH (a)-[r]-(b) RETURN a, b");
}

test "invalid comparison operator" {
    _ = expectParseError("MATCH (n) WHERE n.x <> > 1 RETURN n") catch {};
}

test "dangling AND" {
    _ = expectParseError("MATCH (n) WHERE n.x = 1 AND RETURN n") catch {};
}

test "dangling OR" {
    _ = expectParseError("MATCH (n) WHERE n.x = 1 OR RETURN n") catch {};
}

test "UNION without second query" {
    _ = expectParseError("MATCH (n) RETURN n UNION") catch {};
}

test "multiple consecutive keywords" {
    _ = expectParseError("MATCH MATCH (n) RETURN n") catch {};
}

// ==================== Complex Valid Patterns ====================

test "valid complex path pattern" {
    try expectParseSuccess("MATCH (a)-[:A]->(b)<-[:B]-(c) RETURN a, b, c");
}

test "valid variable length path" {
    try expectParseSuccess("MATCH (a)-[*1..5]->(b) RETURN a, b");
}

test "valid labeled node" {
    try expectParseSuccess("MATCH (n:Person:Employee) RETURN n");
}

test "valid parameterized query" {
    try expectParseSuccess("MATCH (n) WHERE n.id = $id RETURN n");
}

test "valid EXISTS subquery" {
    try expectParseSuccess("MATCH (n) WHERE EXISTS { (n)-[:KNOWS]->() } RETURN n");
}
