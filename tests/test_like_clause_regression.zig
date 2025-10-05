const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// CANARY: REQ=REQ-GQL-LIKE-001; FEATURE="LIKE Clause Parsing Fix"; ASPECT=RegressionTesting; STATUS=IMPL; TEST=TestLikeClauseRegression; OWNER=parser; UPDATED=2025-10-04

test "LIKE clause regression tests" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test LIKE clause without ANY keyword (this was the bug)
    {
        const query = "CREATE GRAPH like_test_graph LIKE source_graph";
        var lexer = geode.gql.Lexer.init(query);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var parser = geode.gql.Parser.init(&lexer, &arena);
        const program = parser.parseProgram() catch |err| {
            std.log.err("Failed to parse LIKE clause without ANY: {}", .{err});
            return err;
        };

        try testing.expect(program.statements.len == 1);
        try testing.expect(program.statements[0] == .CreateGraph);

        const create_graph = program.statements[0].CreateGraph;
        try testing.expectEqualStrings("like_test_graph", create_graph.name);
        try testing.expect(create_graph.like_source != null);
        try testing.expectEqualStrings("source_graph", create_graph.like_source.?);
        try testing.expect(create_graph.typed_spec == null);
        try testing.expect(create_graph.copy_source == null);
    }

    // Test PROPERTY GRAPH with LIKE
    {
        const query = "CREATE PROPERTY GRAPH prop_like_test LIKE base_graph";
        var lexer = geode.gql.Lexer.init(query);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var parser = geode.gql.Parser.init(&lexer, &arena);
        const program = parser.parseProgram() catch |err| {
            std.log.err("Failed to parse PROPERTY GRAPH with LIKE: {}", .{err});
            return err;
        };

        try testing.expect(program.statements.len == 1);
        try testing.expect(program.statements[0] == .CreateGraph);

        const create_graph = program.statements[0].CreateGraph;
        try testing.expectEqualStrings("prop_like_test", create_graph.name);
        try testing.expect(create_graph.property_graph);
        try testing.expect(create_graph.like_source != null);
        try testing.expectEqualStrings("base_graph", create_graph.like_source.?);
    }

    // Test OR REPLACE with LIKE
    {
        const query = "CREATE OR REPLACE GRAPH replace_like_test LIKE template_graph";
        var lexer = geode.gql.Lexer.init(query);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var parser = geode.gql.Parser.init(&lexer, &arena);
        const program = parser.parseProgram() catch |err| {
            std.log.err("Failed to parse OR REPLACE with LIKE: {}", .{err});
            return err;
        };

        try testing.expect(program.statements.len == 1);
        try testing.expect(program.statements[0] == .CreateGraph);

        const create_graph = program.statements[0].CreateGraph;
        try testing.expectEqualStrings("replace_like_test", create_graph.name);
        try testing.expect(create_graph.or_replace);
        try testing.expect(create_graph.like_source != null);
        try testing.expectEqualStrings("template_graph", create_graph.like_source.?);
    }

    // Test that LIKE and AS COPY OF are mutually exclusive
    {
        const query = "CREATE GRAPH invalid_test LIKE source AS COPY OF template";
        var lexer = geode.gql.Lexer.init(query);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var parser = geode.gql.Parser.init(&lexer, &arena);
        const result = parser.parseProgram();

        // This should fail because LIKE and AS COPY OF cannot be combined
        try testing.expectError(geode.gql.ParserError.UnexpectedToken, result);
    }
}

test "LIKE clause edge cases" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test LIKE with IF NOT EXISTS
    {
        const query = "CREATE GRAPH IF NOT EXISTS conditional_like LIKE base_graph";
        var lexer = geode.gql.Lexer.init(query);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var parser = geode.gql.Parser.init(&lexer, &arena);
        const program = parser.parseProgram() catch |err| {
            std.log.err("Failed to parse IF NOT EXISTS with LIKE: {}", .{err});
            return err;
        };

        try testing.expect(program.statements.len == 1);
        try testing.expect(program.statements[0] == .CreateGraph);

        const create_graph = program.statements[0].CreateGraph;
        try testing.expectEqualStrings("conditional_like", create_graph.name);
        try testing.expect(create_graph.if_not_exists);
        try testing.expect(create_graph.like_source != null);
        try testing.expectEqualStrings("base_graph", create_graph.like_source.?);
    }

    // Test empty source graph name (should fail)
    {
        const query = "CREATE GRAPH test_like LIKE";
        var lexer = geode.gql.Lexer.init(query);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var parser = geode.gql.Parser.init(&lexer, &arena);
        const result = parser.parseProgram();

        // Should fail due to missing source graph name
        try testing.expectError(geode.gql.ParserError.UnexpectedToken, result);
    }
}
