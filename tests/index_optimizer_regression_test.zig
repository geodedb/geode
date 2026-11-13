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
