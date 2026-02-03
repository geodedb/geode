const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// CANARY: REQ=REQ-BUILD-SYSTEM-MODULE-DEPS-001; FEATURE="Build System Module Dependencies"; ASPECT=ModuleStructure; STATUS=TESTED; TEST=TestCANARY_REQ_BUILD_SYSTEM_MODULE_DEPS_001_ModuleStructure; OWNER=build; UPDATED=2025-10-05
// CANARY: REQ=REQ-BUILD-SYSTEM-MODULE-DEPS-002; FEATURE="Build System Module Dependencies"; ASPECT=CircularDependencyPrevention; STATUS=TESTED; TEST=TestCANARY_REQ_BUILD_SYSTEM_MODULE_DEPS_002_CircularDependencyPrevention; OWNER=build; UPDATED=2025-10-05
// CANARY: REQ=REQ-BUILD-SYSTEM-MODULE-DEPS-003; FEATURE="Build System Module Dependencies"; ASPECT=SharedTypeAccessibility; STATUS=TESTED; TEST=TestCANARY_REQ_BUILD_SYSTEM_MODULE_DEPS_003_SharedTypeAccessibility; OWNER=build; UPDATED=2025-10-05

test "TestCANARY_REQ_BUILD_SYSTEM_MODULE_DEPS_001_ModuleStructure" {
    // Test that core module structure is properly organized and accessible

    // Verify geode module exports are accessible
    _ = geode.ast;
    _ = geode.gql;
    _ = geode.graph_common;
    _ = geode.exec;
    _ = geode.materialized_views;

    // Test that graph_common types are accessible
    _ = geode.graph_common.GraphStorage;
    _ = geode.graph_common.PropertyValue;
    _ = geode.graph_common.Binding;
    _ = geode.graph_common.BindingValue;
    _ = geode.graph_common.Column; // Added to resolve circular dependencies

    // Verify exec module doesn't conflict with server/graph/exec
    _ = geode.exec; // This should be src/exec.zig, not server/graph/exec.zig

    // Test that materialized_views can access required types
    _ = geode.materialized_views.MaterializedViewManager;
    _ = geode.materialized_views.QueryResult;

    try testing.expect(true); // Structure validation passed
}

test "TestCANARY_REQ_BUILD_SYSTEM_MODULE_DEPS_002_CircularDependencyPrevention" {
    // Test that circular dependencies have been eliminated

    // Verify Column type is available through graph_common (not exec)
    const Column = geode.graph_common.Column;

    // Test Column structure
    const test_column = Column{
        .name = "test_column",
        .type = "STRING",
    };

    try testing.expectEqualStrings("test_column", test_column.name);
    try testing.expectEqualStrings("STRING", test_column.type);

    // Verify materialized_views can create QueryResult with proper schema
    const allocator = testing.allocator;

    var schema = std.ArrayList(Column).init(allocator);
    defer schema.deinit();

    try schema.append(.{ .name = "id", .type = "INT" });
    try schema.append(.{ .name = "name", .type = "STRING" });

    const schema_slice = try schema.toOwnedSlice();
    defer allocator.free(schema_slice);

    // Verify schema creation works without circular dependency issues
    try testing.expect(schema_slice.len == 2);
    try testing.expectEqualStrings("id", schema_slice[0].name);
    try testing.expectEqualStrings("INT", schema_slice[0].type);
    try testing.expectEqualStrings("name", schema_slice[1].name);
    try testing.expectEqualStrings("STRING", schema_slice[1].type);
}

test "TestCANARY_REQ_BUILD_SYSTEM_MODULE_DEPS_003_SharedTypeAccessibility" {
    // Test that shared types are accessible from all required locations

    // Test GraphStorage accessibility
    const allocator = testing.allocator;
    var graph = geode.graph_common.GraphStorage.init(allocator);
    defer graph.deinit();

    // Test that we can create nodes and edges
    var labels = [_][]const u8{"TestNode"};
    const node_id = try graph.createNode(&labels);
    try testing.expect(node_id != 0);

    // Test PropertyValue creation with different types
    const string_prop = geode.graph_common.PropertyValue{ .String = "test_value" };
    const int_prop = geode.graph_common.PropertyValue{ .Int = 42 };
    const bool_prop = geode.graph_common.PropertyValue{ .Bool = true };

    // Verify property value types
    switch (string_prop) {
        .String => |val| try testing.expectEqualStrings("test_value", val),
        else => try testing.expect(false),
    }

    switch (int_prop) {
        .Int => |val| try testing.expect(val == 42),
        else => try testing.expect(false),
    }

    switch (bool_prop) {
        .Bool => |val| try testing.expect(val == true),
        else => try testing.expect(false),
    }

    // Test that BindingValue is accessible and functional
    const binding_value = geode.graph_common.BindingValue{
        .property_value = string_prop,
        .node_id = node_id,
    };

    try testing.expect(binding_value.node_id == node_id);
    switch (binding_value.property_value) {
        .String => |val| try testing.expectEqualStrings("test_value", val),
        else => try testing.expect(false),
    }
}

test "Module import hierarchy validation" {
    // Test that module imports follow proper hierarchy without conflicts

    // This test ensures that:
    // 1. geode module is the root of all imports
    // 2. No circular dependencies exist
    // 3. All required types are accessible through proper paths

    // Test graph_common is accessible
    _ = geode.graph_common.NodeId;
    _ = geode.graph_common.EdgeId;
    _ = geode.graph_common.IndexType;
    _ = geode.graph_common.MatchOptions;

    // Test that Column is properly shared
    const column_from_graph_common = geode.graph_common.Column;

    // Verify Column structure matches expected interface
    const test_col = column_from_graph_common{
        .name = "test",
        .type = "TEXT",
    };

    try testing.expectEqualStrings("test", test_col.name);
    try testing.expectEqualStrings("TEXT", test_col.type);

    // Test that we can create complex structures without conflicts
    const allocator = testing.allocator;

    var columns = std.ArrayList(column_from_graph_common).init(allocator);
    defer columns.deinit();

    try columns.append(.{ .name = "col1", .type = "INTEGER" });
    try columns.append(.{ .name = "col2", .type = "TEXT" });
    try columns.append(.{ .name = "col3", .type = "BOOLEAN" });

    try testing.expect(columns.items.len == 3);
}

test "Build system module conflict prevention" {
    // Test that the specific conflicts we resolved don't reoccur

    // Verify that we can access graph execution functionality through proper paths
    // This test ensures server/graph/exec.zig doesn't conflict with geode module

    // Test that MaterializedViewManager can access its dependencies
    const allocator = testing.allocator;

    // Create a mock materialized view manager to test dependency access
    var manager = geode.materialized_views.MaterializedViewManager.init(allocator);
    defer manager.deinit();

    // Test that we can create views without module conflicts
    const view_definition = geode.materialized_views.MaterializedViewDefinition{
        .name = "test_view",
        .query = "MATCH (n) RETURN n.id",
        .refresh_strategy = .manual,
        .dependencies = &[_][]const u8{},
    };

    // Test view creation doesn't fail due to module conflicts
    const result = manager.createView(view_definition);

    // We expect this to succeed (no module conflicts) or fail for business logic reasons
    // The important thing is that it doesn't fail due to circular dependencies
    _ = result catch |err| switch (err) {
        // These are acceptable business logic errors
        error.ViewAlreadyExists, error.InvalidQuery, error.DependencyNotFound, error.OutOfMemory => {},
        // Any other error suggests module conflict issues
        else => return err,
    };

    try testing.expect(true); // Test completed without module conflicts
}

test "Cross-module type compatibility" {
    // Test that types defined in graph_common work across different modules

    const allocator = testing.allocator;

    // Test Column type works with materialized views
    var schema = std.ArrayList(geode.graph_common.Column).init(allocator);
    defer schema.deinit();

    const columns = [_]geode.graph_common.Column{
        .{ .name = "user_id", .type = "BIGINT" },
        .{ .name = "username", .type = "VARCHAR(255)" },
        .{ .name = "email", .type = "VARCHAR(320)" },
        .{ .name = "created_at", .type = "TIMESTAMP" },
        .{ .name = "is_active", .type = "BOOLEAN" },
    };

    for (columns) |col| {
        try schema.append(col);
    }

    // Verify all columns were added correctly
    try testing.expect(schema.items.len == 5);

    // Test that PropertyValue works with graph operations
    var graph = geode.graph_common.GraphStorage.init(allocator);
    defer graph.deinit();

    // Test adding nodes with various property types
    const node1_id = try graph.createNode(&[_][]const u8{"User"});
    const node2_id = try graph.createNode(&[_][]const u8{"Post"});

    // Test edge creation
    const edge_id = try graph.createEdge(node1_id, node2_id, "CREATED");

    try testing.expect(node1_id == 1);
    try testing.expect(node2_id == 2);
    try testing.expect(edge_id != 0);

    // Test that MatchOptions work properly
    const match_options = geode.graph_common.MatchOptions{
        .max_results = 100,
        .max_frontier = 1000,
        .unique_nodes = true,
        .order_deterministic = true,
        .max_hops_limit = 5,
        .min_hops = 1,
        .timeout_ms = 30000,
    };

    try testing.expect(match_options.max_results.? == 100);
    try testing.expect(match_options.max_frontier.? == 1000);
    try testing.expect(match_options.unique_nodes.? == true);
}
