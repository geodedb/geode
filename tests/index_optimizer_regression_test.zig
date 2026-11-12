const std = @import("std");
const testing = std.testing;

// Test that SET/REMOVE clause implementations don't break compilation
test "TestCANARY_REQ_GQL_016_SetRemoveClauseImplementation" {
    const graph_common = @import("../src/types/graph_common.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test GraphStore property manipulation methods
    var graph = try graph_common.GraphStore.init(allocator);
    defer graph.deinit();

    // Add a test node
    var labels = [_][]const u8{"Person"};
    const node_id = try graph.createNode(&labels);

    // Test setting and removing properties
    try graph.setNodeProperty(node_id, "name", .{ .String = "Alice" });

    // Verify property was set
    if (graph.getNodeProperty(node_id, "name")) |prop| {
        try testing.expect(prop == .String);
        try testing.expect(std.mem.eql(u8, prop.String, "Alice"));
    } else {
        try testing.expect(false); // Property should exist
    }

    // Test removing property
    try graph.removeNodeProperty(node_id, "name");

    // Verify property was removed
    try testing.expect(graph.getNodeProperty(node_id, "name") == null);
}

// Test that WITH clause execution compiles
test "TestCANARY_REQ_GQL_016_WithClauseImplementation" {
    const graph_exec = @import("../src/server/graph/exec.zig");
    const ast = @import("../src/gql/ast.zig");
    const graph_common = @import("../src/types/graph_common.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a minimal WITH clause for testing
    const with_items = [_]ast.ReturnItem{
        .{ .expr = .{ .Ident = .{ .orig = "n", .cnf = "N" } }, .alias = "node" },
    };

    const with_clause = ast.WithClause{ .items = &with_items };

    // Create test input bindings
    var input_binding = graph_common.Binding.init(allocator);
    const test_node = graph_common.Node{
        .id = 1,
        .labels = &[_][]const u8{"Person"},
        .properties = std.StringHashMap(graph_common.PropertyValue).init(allocator),
    };
    try input_binding.vars.put("n", .{ .Node = test_node });

    const input_bindings = [_]graph_common.Binding{input_binding};

    // Create test graph
    var graph = try graph_common.GraphStore.init(allocator);
    defer graph.deinit();

    // This should compile and execute without errors
    const result = try graph_exec.executeWith(allocator, &input_bindings, with_clause, null, &graph);
    defer allocator.free(result);

    // Verify basic functionality
    try testing.expect(result.len == 1);
}
