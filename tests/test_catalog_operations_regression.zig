const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// CANARY: REQ=REQ-GQL-CATALOG-001; FEATURE="Enhanced Catalog Operations"; ASPECT=RegressionTesting; STATUS=IMPL; TEST=TestCatalogOperationsRegression; OWNER=parser; UPDATED=2025-10-04

test "catalog operations regression tests" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test TYPED clause parsing
    {
        const query = "CREATE GRAPH typed_test TYPED ANY";
        var lexer = geode.gql.Lexer.init(query);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var parser = geode.gql.Parser.init(&lexer, &arena);
        const program = parser.parseProgram() catch |err| {
            std.log.err("Failed to parse TYPED clause: {}", .{err});
            return err;
        };

        try testing.expect(program.statements.len == 1);
        try testing.expect(program.statements[0] == .CreateGraph);

        const create_graph = program.statements[0].CreateGraph;
        try testing.expectEqualStrings("typed_test", create_graph.name);
        try testing.expect(create_graph.typed_spec != null);
        try testing.expectEqualStrings("ANY", create_graph.typed_spec.?);
    }

    // Test AS COPY OF clause parsing
    {
        const query = "CREATE GRAPH copy_test ANY AS COPY OF source_graph";
        var lexer = geode.gql.Lexer.init(query);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var parser = geode.gql.Parser.init(&lexer, &arena);
        const program = parser.parseProgram() catch |err| {
            std.log.err("Failed to parse AS COPY OF clause: {}", .{err});
            return err;
        };

        try testing.expect(program.statements.len == 1);
        try testing.expect(program.statements[0] == .CreateGraph);

        const create_graph = program.statements[0].CreateGraph;
        try testing.expectEqualStrings("copy_test", create_graph.name);
        try testing.expect(create_graph.copy_source != null);
        try testing.expectEqualStrings("source_graph", create_graph.copy_source.?);
    }

    // Test OR REPLACE with TYPED
    {
        const query = "CREATE OR REPLACE GRAPH replace_test TYPED ANY";
        var lexer = geode.gql.Lexer.init(query);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var parser = geode.gql.Parser.init(&lexer, &arena);
        const program = parser.parseProgram() catch |err| {
            std.log.err("Failed to parse OR REPLACE with TYPED: {}", .{err});
            return err;
        };

        try testing.expect(program.statements.len == 1);
        try testing.expect(program.statements[0] == .CreateGraph);

        const create_graph = program.statements[0].CreateGraph;
        try testing.expectEqualStrings("replace_test", create_graph.name);
        try testing.expect(create_graph.or_replace);
        try testing.expect(create_graph.typed_spec != null);
        try testing.expectEqualStrings("ANY", create_graph.typed_spec.?);
    }

    // Test PROPERTY GRAPH with TYPED
    {
        const query = "CREATE PROPERTY GRAPH prop_test TYPED ANY PROPERTY GRAPH";
        var lexer = geode.gql.Lexer.init(query);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var parser = geode.gql.Parser.init(&lexer, &arena);
        const program = parser.parseProgram() catch |err| {
            std.log.err("Failed to parse PROPERTY GRAPH with TYPED: {}", .{err});
            return err;
        };

        try testing.expect(program.statements.len == 1);
        try testing.expect(program.statements[0] == .CreateGraph);

        const create_graph = program.statements[0].CreateGraph;
        try testing.expectEqualStrings("prop_test", create_graph.name);
        try testing.expect(create_graph.property_graph);
        try testing.expect(create_graph.typed_spec != null);
        try testing.expectEqualStrings("ANY", create_graph.typed_spec.?);
    }

    // Test traditional CREATE GRAPH still works
    {
        const query = "CREATE GRAPH simple_test ANY";
        var lexer = geode.gql.Lexer.init(query);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var parser = geode.gql.Parser.init(&lexer, &arena);
        const program = parser.parseProgram() catch |err| {
            std.log.err("Failed to parse traditional CREATE GRAPH: {}", .{err});
            return err;
        };

        try testing.expect(program.statements.len == 1);
        try testing.expect(program.statements[0] == .CreateGraph);

        const create_graph = program.statements[0].CreateGraph;
        try testing.expectEqualStrings("simple_test", create_graph.name);
        try testing.expect(create_graph.typed_spec == null);
        try testing.expect(create_graph.copy_source == null);
        try testing.expect(create_graph.like_source == null);
    }
}

test "catalog operations error cases" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test invalid TYPED syntax
    {
        const query = "CREATE GRAPH invalid_test TYPED";
        var lexer = geode.gql.Lexer.init(query);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var parser = geode.gql.Parser.init(&lexer, &arena);
        const result = parser.parseProgram();
        try testing.expectError(geode.gql.ParserError.UnexpectedToken, result);
    }

    // Test invalid AS COPY OF syntax
    {
        const query = "CREATE GRAPH invalid_test AS COPY";
        var lexer = geode.gql.Lexer.init(query);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var parser = geode.gql.Parser.init(&lexer, &arena);
        const result = parser.parseProgram();
        try testing.expectError(geode.gql.ParserError.UnexpectedToken, result);
    }
}

// CANARY: REQ=REQ-GQL-CATALOG-002; FEATURE="Graph Type Operations"; ASPECT=FrameworkTesting; STATUS=IMPL; TEST=TestGraphTypeFramework; OWNER=parser; UPDATED=2025-10-04

test "graph type operations framework" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test that CREATE GRAPH TYPE parsing infrastructure exists
    // (Currently disabled but framework should be present)
    {
        const query = "CREATE GRAPH TYPE test_type AS { }";
        var lexer = geode.gql.Lexer.init(query);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var parser = geode.gql.Parser.init(&lexer, &arena);
        // Should return UnexpectedToken since feature is disabled
        const result = parser.parseProgram();
        try testing.expectError(geode.gql.ParserError.UnexpectedToken, result);
    }

    // Verify AST structures exist for future implementation
    {
        const create_graph_type = geode.gql.ast.CreateGraphTypeStatement{
            .name = "test_type",
            .if_not_exists = false,
            .or_replace = false,
            .property_graph = true,
            .type_definition = "{ }",
            .like_source = null,
            .copy_source = null,
        };

        try testing.expectEqualStrings("test_type", create_graph_type.name);
        try testing.expectEqualStrings("{ }", create_graph_type.type_definition);
    }
}
