const std = @import("std");
const geode = @import("geode");
const Parser = geode.gql.parser.Parser;
const Lexer = geode.gql.lexer.Lexer;

// CANARY: REQ=REQ-GQL-COMPLIANCE-001; FEATURE="GQL Compliance Regression"; ASPECT=Parser; STATUS=TESTED; TEST=tests/gql_compliance_regression_test.zig; OWNER=parser; UPDATED=2026-11-14

test "TestCANARY_REQ_GQL_COMPLIANCE_001_Parser: Full GQL compliance maintained" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Core test cases that must always pass for 100% GQL compliance
    const critical_cases = [_][]const u8{
        // The originally failing case that triggered this work
        "MATCH path = (a:Person)-[:KNOWS*2..4]->(b:Person) RETURN a.name, b.name, length(path)",

        // String concatenation
        "RETURN 'hello' || ' world' AS concatenated",

        // Aggregation functions
        "MATCH (n) RETURN COUNT(n) AS count",
        "MATCH (n) RETURN SUM(n.value) AS `sum`",
        "MATCH (n) RETURN AVG(n.score) AS average",
        "MATCH (n) RETURN MIN(n.age) AS minimum",
        "MATCH (n) RETURN MAX(n.age) AS maximum",

        // SET/REMOVE operations
        "MATCH (n) SET n.property = 'value'",
        "MATCH (n) REMOVE n.property",
        "MATCH (n) SET n.age = 30 RETURN n",
        "MATCH (n) REMOVE n.temp RETURN count(n)",

        // Variable-length paths
        "MATCH (a)-[*1..3]->(b) RETURN a, b",
        "MATCH (a)-[*..5]->(b) RETURN a, b",
        "MATCH (a)-[*2..]->(b) RETURN a, b",

        // Session management
        "USE GRAPH social_network",
        "SET SESSION GRAPH = 'production'",

        // Transaction control
        "START TRANSACTION",
        "COMMIT",
        "ROLLBACK",

        // MERGE operations
        "MERGE (n:Person {id: 1}) ON CREATE SET n.created = now() ON MATCH SET n.accessed = now()",

        // DETACH DELETE
        "MATCH (n) DETACH DELETE n",

        // Built-in functions
        "RETURN upper('hello') AS upper_case",
        "RETURN lower('WORLD') AS lower_case",
        "RETURN length('test') AS string_length",
        "RETURN abs(-5) AS absolute",
        "RETURN sqrt(16) AS square_root",
    };

    var passed: u32 = 0;
    var failed: u32 = 0;

    for (critical_cases) |query| {
        var l = Lexer{ .src = query };
        var p = Parser{ .lx = &l, .arena = &arena, .cur = l.next() };

        const result = p.parseProgram();
        if (result == error.UnexpectedToken) {
            std.debug.print("REGRESSION: Failed to parse: {s}\n", .{query});
            failed += 1;
        } else {
            const program = result catch unreachable;
            if (program.statements.len == 0) {
                std.debug.print("REGRESSION: Empty program for: {s}\n", .{query});
                failed += 1;
            } else {
                passed += 1;
            }
        }
    }

    // Require 100% success rate for regression test
    try std.testing.expect(failed == 0);
    try std.testing.expect(passed == critical_cases.len);
}

test "TestCANARY_REQ_GQL_COMPLIANCE_002_Parser: Error cases still fail correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // These should still fail as expected (syntax errors)
    const error_cases = [_][]const u8{
        "MATCH (n:) RETURN n", // Missing label name
        "RETURN (1 + 2", // Unclosed parenthesis
        "RETURN MATCH", // A reserved word as an identifier (ISO/IEC 39075 21.3; SONNY-6564)
        "MATCH (n) SET = value", // Missing property
        "MATCH (n) REMOVE", // Missing property
        "MATCH (n) SET n. = 1", // Missing property name
    };

    for (error_cases) |query| {
        var l = Lexer{ .src = query };
        var p = Parser{ .lx = &l, .arena = &arena, .cur = l.next() };

        // These SHOULD fail
        if (p.parseProgram()) |_| {
            std.debug.print("accepted: {s}\n", .{query});
            return error.TestUnexpectedResult;
        } else |err| {
            if (err != error.UnexpectedToken) std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            try std.testing.expect(err == error.UnexpectedToken);
        }
    }
}

test "TestCANARY_REQ_GQL_COMPLIANCE_003_Parser: Complex integration scenarios" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Complex scenarios combining multiple fixed features
    const complex_cases = [_][]const u8{
        // Path variables + aggregation + keywords
        "MATCH path = (a:Person)-[:KNOWS*2..4]->(b:Person) RETURN COUNT(path) AS count",

        // SET/REMOVE + aggregation + keywords
        "MATCH (n) SET n.property = 'value' RETURN SUM(n.count) AS `sum`",

        // Multiple path variables with keywords
        "MATCH path = (a)-[:KNOWS]->(b), route = (b)-[:LIVES_IN]->(c) RETURN length(path) + length(route) AS total",

        // Complex MERGE with keyword properties
        "MERGE (n:Person {type: 'user'}) ON CREATE SET n.property = 'new' ON MATCH SET n.count = n.count + 1 RETURN n.property AS property",

        // Nested function calls with keywords
        "MATCH path = (a)-[:KNOWS*1..3]->(b) RETURN upper(lower(substring(path, 0, length(path)))) AS processed",

        // Complex WHERE with SET/REMOVE
        "MATCH (n:Person) WHERE n.type IN ['admin', 'user'] SET n.property = n.count || '_processed' REMOVE n.temporary RETURN COUNT(n) AS count",
    };

    for (complex_cases) |query| {
        var l = Lexer{ .src = query };
        var p = Parser{ .lx = &l, .arena = &arena, .cur = l.next() };

        const result = p.parseProgram();
        try std.testing.expect(result != error.UnexpectedToken);

        const program = result catch unreachable;
        try std.testing.expect(program.statements.len == 1);
    }
}
