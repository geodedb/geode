const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// CANARY: REQ=REQ-GQL-CATALOG-003; FEATURE="End-to-End Catalog Operations"; ASPECT=IntegrationTesting; STATUS=TESTED; TEST=geodetestlab/specs/gql_catalog_operations_comprehensive.yml; TEST=TestCatalogE2E; OWNER=server; UPDATED=2025-10-04

test "catalog operations end-to-end integration" {
    // This test validates that the enhanced catalog operations work end-to-end
    // through the server execution pipeline

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a temporary test database
    const test_dir = "/tmp/geode_catalog_test";
    std.fs.cwd().deleteTree(test_dir) catch {};
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Test catalog operation workflow
    var server_state = geode.server.ServerState.init(allocator, test_dir) catch |err| {
        std.log.err("Failed to initialize server state: {}", .{err});
        return err;
    };
    defer server_state.deinit();

    // Test 1: CREATE GRAPH with TYPED syntax
    {
        const query = "CREATE GRAPH typed_integration_test TYPED ANY";
        const response = server_state.executeQuery(query) catch |err| {
            std.log.err("Failed to execute TYPED graph creation: {}", .{err});
            return err;
        };

        // Verify successful creation
        try testing.expect(std.mem.indexOf(u8, response, "property graph typed_integration_test created successfully") != null);
    }

    // Test 2: CREATE GRAPH with AS COPY OF syntax
    {
        // First create a source graph
        const source_query = "CREATE GRAPH copy_source_test ANY";
        _ = server_state.executeQuery(source_query) catch |err| {
            std.log.err("Failed to create source graph: {}", .{err});
            return err;
        };

        // Then create a copy
        const copy_query = "CREATE GRAPH copy_target_test ANY AS COPY OF copy_source_test";
        const response = server_state.executeQuery(copy_query) catch |err| {
            std.log.err("Failed to execute AS COPY OF graph creation: {}", .{err});
            return err;
        };

        // Verify successful creation
        try testing.expect(std.mem.indexOf(u8, response, "property graph copy_target_test created successfully") != null);
    }

    // Test 3: CREATE OR REPLACE workflow
    {
        // Create initial graph
        const initial_query = "CREATE GRAPH replace_test_graph TYPED ANY";
        _ = server_state.executeQuery(initial_query) catch |err| {
            std.log.err("Failed to create initial graph for replace test: {}", .{err});
            return err;
        };

        // Replace it
        const replace_query = "CREATE OR REPLACE GRAPH replace_test_graph TYPED ANY";
        const response = server_state.executeQuery(replace_query) catch |err| {
            std.log.err("Failed to execute OR REPLACE graph creation: {}", .{err});
            return err;
        };

        // Verify successful replacement
        try testing.expect(std.mem.indexOf(u8, response, "property graph replace_test_graph replaced successfully") != null);
    }

    // Test 4: Property graph variations
    {
        const query = "CREATE PROPERTY GRAPH property_typed_test TYPED ANY PROPERTY GRAPH";
        const response = server_state.executeQuery(query) catch |err| {
            std.log.err("Failed to execute PROPERTY GRAPH with TYPED: {}", .{err});
            return err;
        };

        // Verify successful creation
        try testing.expect(std.mem.indexOf(u8, response, "property graph property_typed_test created successfully") != null);
    }

    // Test 5: Verify backward compatibility
    {
        const query = "CREATE GRAPH backward_compat_test ANY";
        const response = server_state.executeQuery(query) catch |err| {
            std.log.err("Failed to execute backward compatible graph creation: {}", .{err});
            return err;
        };

        // Verify successful creation
        try testing.expect(std.mem.indexOf(u8, response, "property graph backward_compat_test created successfully") != null);
    }
}

// CANARY: REQ=REQ-GQL-CATALOG-004; FEATURE="Error Handling Regression"; ASPECT=ErrorTesting; STATUS=TESTED; TEST=geodetestlab/specs/geode_edge_cases_errors.yml; TEST=TestCatalogErrorHandling; OWNER=server; UPDATED=2025-10-04

test "catalog operations error handling regression" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a temporary test database
    const test_dir = "/tmp/geode_catalog_error_test";
    std.fs.cwd().deleteTree(test_dir) catch {};
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var server_state = geode.server.ServerState.init(allocator, test_dir) catch |err| {
        std.log.err("Failed to initialize server state: {}", .{err});
        return err;
    };
    defer server_state.deinit();

    // Test error case: Invalid TYPED syntax
    {
        const query = "CREATE GRAPH invalid_typed_test TYPED";
        const response = server_state.executeQuery(query) catch |err| {
            // Should get a parse error - this is expected
            try testing.expect(err == geode.server.QueryError.ParseError);
            return; // Test passed
        };

        // If we get here, the query unexpectedly succeeded
        std.log.err("Expected parse error for invalid TYPED syntax, but got: {s}", .{response});
        try testing.expect(false);
    }

    // Test error case: Invalid AS COPY OF syntax
    {
        const query = "CREATE GRAPH invalid_copy_test AS COPY";
        const response = server_state.executeQuery(query) catch |err| {
            // Should get a parse error - this is expected
            try testing.expect(err == geode.server.QueryError.ParseError);
            return; // Test passed
        };

        // If we get here, the query unexpectedly succeeded
        std.log.err("Expected parse error for invalid AS COPY OF syntax, but got: {s}", .{response});
        try testing.expect(false);
    }

    // Test error case: Missing graph name
    {
        const query = "CREATE GRAPH TYPED ANY";
        const response = server_state.executeQuery(query) catch |err| {
            // Should get a parse error - this is expected
            try testing.expect(err == geode.server.QueryError.ParseError);
            return; // Test passed
        };

        // If we get here, the query unexpectedly succeeded
        std.log.err("Expected parse error for missing graph name, but got: {s}", .{response});
        try testing.expect(false);
    }
}
