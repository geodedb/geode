const std = @import("std");
const testing = std.testing;

// Regression test for IndexOptimizer circular dependency fix
// CANARY: REQ=REQ-GQL-016; FEATURE="IndexOptimizer"; ASPECT=CircularDependencyFix; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_016_IndexOptimizerCircularFix; OWNER=engine; UPDATED=2025-10-03
test "TestCANARY_REQ_GQL_016_IndexOptimizerCircularFix" {
    // This test verifies that the IndexOptimizer can be imported and used
    // without circular dependency issues that were present in issue #16

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const graph_common = @import("../src/types/graph_common.zig");
    const IndexOptimizer = @import("../src/server/index_optimizer.zig").IndexOptimizer;

    // Mock index manager
    const MockIndexManager = struct {
        property_indexes: std.StringHashMap(void),

        pub fn init(alloc: std.mem.Allocator) @This() {
            return .{ .property_indexes = std.StringHashMap(void).init(alloc) };
        }

        pub fn deinit(self: *@This()) void {
            self.property_indexes.deinit();
        }

        pub fn lookupPropertyIndex(self: *@This(), index_name: []const u8, search_key: []const u8) !?u64 {
            _ = search_key;
            if (self.property_indexes.contains(index_name)) {
                return 1;
            }
            return null;
        }
    };

    var mock_index_manager = MockIndexManager.init(allocator);
    defer mock_index_manager.deinit();

    // This should compile and work without circular dependency errors
    var optimizer = IndexOptimizer.init(allocator, &mock_index_manager);

    const labels = [_][]const u8{"Person"};
    const plan = optimizer.optimizeNodeScan(&labels, "n", null, null);

    // Verify basic functionality
    try testing.expect(plan.type == .sequential);
    try testing.expect(plan.estimated_cost > 0);
    try testing.expect(plan.estimated_rows > 0);
}

// Test that SET/REMOVE clause implementations don't break compilation
test "TestCANARY_REQ_GQL_016_SetRemoveClauseImplementation" {
    const graph_common = @import("../src/types/graph_common.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test GraphStorage property manipulation methods
    var graph = graph_common.GraphStorage.init(allocator);
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
    var graph = graph_common.GraphStorage.init(allocator);
    defer graph.deinit();

    // This should compile and execute without errors
    const result = try graph_exec.executeWith(allocator, &input_bindings, with_clause, null, &graph);
    defer allocator.free(result);

    // Verify basic functionality
    try testing.expect(result.len == 1);
}
