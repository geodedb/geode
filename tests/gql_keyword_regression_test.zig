const std = @import("std");
const geode = @import("geode");
const Parser = geode.gql.parser.Parser;
const Lexer = geode.gql.lexer.Lexer;

// CANARY: REQ=REQ-GQL-KEYWORD-001; FEATURE="GQL Keyword Handling"; ASPECT=Parser; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_KEYWORD_001_Parser; OWNER=parser; UPDATED=2026-11-14

test "TestCANARY_REQ_GQL_KEYWORD_001_Parser: Path variable assignment with PATH keyword" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const test_cases = [_][]const u8{
        // Path variable assignment (the original failing case from GQL compliance)
        "MATCH path = (a:Person)-[:KNOWS*2..4]->(b:Person) RETURN a.name, b.name, length(path)",

        // Simple path variable assignments
        "MATCH path = (a)-[:KNOWS]->(b) RETURN path",
        "MATCH path = (a:Person)-[:KNOWS]->(b:Person) RETURN path",

        // Path variable with different quantifiers
        "MATCH path = (a)-[*1..3]->(b) RETURN path",
        "MATCH path = (a)-[*..5]->(b) RETURN path",
        "MATCH path = (a)-[*2..]->(b) RETURN path",
    };

    for (test_cases) |query| {
        var l = Lexer{ .src = query };
        var p = Parser{ .lx = &l, .arena = &arena, .cur = l.next() };

        const result = p.parseProgram();
        try std.testing.expect(result != error.UnexpectedToken);

        const program = result catch unreachable;
        try std.testing.expect(program.statements.len == 1);
    }
}

test "TestCANARY_REQ_GQL_KEYWORD_002_Parser: Aggregation function aliases with keywords" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const test_cases = [_][]const u8{
        // Aggregation functions with keyword aliases (previously failing)
        "MATCH (n) RETURN COUNT(n) AS count",
        "MATCH (n) RETURN SUM(n.value) AS sum",
        "MATCH (n) RETURN AVG(n.score) AS avg",
        "MATCH (n) RETURN MIN(n.age) AS min",
        "MATCH (n) RETURN MAX(n.age) AS max",

        // With PATH keyword alias
        "MATCH (n) RETURN COUNT(n) AS path",
        "MATCH (n) RETURN LENGTH(n.name) AS type",
        "MATCH (n) RETURN SIZE(n.list) AS value",
    };

    for (test_cases) |query| {
        var l = Lexer{ .src = query };
        var p = Parser{ .lx = &l, .arena = &arena, .cur = l.next() };

        const result = p.parseProgram();
        try std.testing.expect(result != error.UnexpectedToken);

        const program = result catch unreachable;
        try std.testing.expect(program.statements.len == 1);
    }
}

test "TestCANARY_REQ_GQL_KEYWORD_003_Parser: SET/REMOVE with keyword property names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const test_cases = [_][]const u8{
        // SET/REMOVE with keyword property names (previously failing)
        "MATCH (n) SET n.property = 'value'",
        "MATCH (n) REMOVE n.property",
        "MATCH (n) SET n.type = 'Person'",
        "MATCH (n) REMOVE n.type",
        "MATCH (n) SET n.path = 'some/path'",
        "MATCH (n) REMOVE n.path",

        // Multiple properties including keywords
        "MATCH (n) SET n.property = 'value', n.count = 1, n.path = '/home'",
        "MATCH (n) REMOVE n.property, n.type, n.count",

        // With RETURN clause
        "MATCH (n) SET n.property = 'value' RETURN n.property",
        "MATCH (n) REMOVE n.property RETURN count(n)",
    };

    for (test_cases) |query| {
        var l = Lexer{ .src = query };
        var p = Parser{ .lx = &l, .arena = &arena, .cur = l.next() };

        const result = p.parseProgram();
        try std.testing.expect(result != error.UnexpectedToken);

        const program = result catch unreachable;
        try std.testing.expect(program.statements.len == 1);
    }
}

test "TestCANARY_REQ_GQL_KEYWORD_004_Parser: Function calls with keyword arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const test_cases = [_][]const u8{
        // Function calls with keyword variables (the length(path) case)
        "MATCH path = (a)-[:KNOWS]->(b) RETURN length(path)",
        "MATCH count = (a)-[:KNOWS]->(b) RETURN size(count)",
        "MATCH type = (a)-[:IS]->(b) RETURN upper(type)",

        // Built-in functions with keyword arguments
        "RETURN length(path) AS path_length",
        "RETURN upper(type) AS upper_type",
        "RETURN lower(property) AS lower_property",
    };

    for (test_cases) |query| {
        var l = Lexer{ .src = query };
        var p = Parser{ .lx = &l, .arena = &arena, .cur = l.next() };

        const result = p.parseProgram();
        try std.testing.expect(result != error.UnexpectedToken);

        const program = result catch unreachable;
        try std.testing.expect(program.statements.len == 1);
    }
}

test "TestCANARY_REQ_GQL_KEYWORD_005_Parser: Keywords in different contexts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const test_cases = [_][]const u8{
        // Keywords as identifiers in various contexts
        "MATCH (path:Person) RETURN path.name",
        "MATCH (count:Counter) SET count.value = 1",
        "MATCH (type:TypeInfo) REMOVE type.temporary",
        "MATCH (property:Metadata) RETURN property",

        // Complex combinations
        "MATCH path = (count:Counter)-[:HAS_TYPE]->(type:TypeInfo) SET type.property = path",
        "MATCH (n) WHERE n.type = 'path' RETURN count(n) AS path",
    };

    for (test_cases) |query| {
        var l = Lexer{ .src = query };
        var p = Parser{ .lx = &l, .arena = &arena, .cur = l.next() };

        const result = p.parseProgram();
        try std.testing.expect(result != error.UnexpectedToken);

        const program = result catch unreachable;
        try std.testing.expect(program.statements.len == 1);
    }
}
