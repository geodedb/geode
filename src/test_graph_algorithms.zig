const std = @import("std");
const testing = std.testing;
const graph_store = @import("graph_store.zig");

test "Graph store - create and retrieve nodes" {
    const allocator = testing.allocator;
    
    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    
    // Clear any existing data
    store.clearNodes();
    
    // Create a node with label
    const labels = [_][]const u8{"TestNode"};
    const labels_slice: [][]const u8 = @constCast(&labels);
    const node_id = try store.createNode(labels_slice);
    
    // Verify node was created
    try testing.expect(store.nodes.contains(node_id));
    
    // Get the node
    if (store.nodes.get(node_id)) |node| {
        try testing.expectEqual(@as(u64, node_id), node.id);
        try testing.expectEqual(@as(usize, 1), node.labels.len);
        try testing.expectEqualStrings("TestNode", node.labels[0]);
    } else {
        try testing.expect(false); // Node should exist
    }
}

test "Graph store - create edges between nodes" {
    const allocator = testing.allocator;
    
    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    
    store.clearNodes();
    
    // Create two nodes
    const labels_a = [_][]const u8{"NodeA"};
    const labels_b = [_][]const u8{"NodeB"};
    const labels_a_slice: [][]const u8 = @constCast(&labels_a);
    const labels_b_slice: [][]const u8 = @constCast(&labels_b);
    const node_a = try store.createNode(labels_a_slice);
    const node_b = try store.createNode(labels_b_slice);
    
    // Create an edge between them
    const edge_id = try store.createEdge(node_a, node_b, "CONNECTS");
    
    // Verify edge was created
    try testing.expect(store.edges.contains(edge_id));
    
    // Get the edge and verify properties
    if (store.edges.get(edge_id)) |edge| {
        try testing.expectEqual(@as(u64, edge_id), edge.id);
        try testing.expectEqual(@as(u64, node_a), edge.from_id);
        try testing.expectEqual(@as(u64, node_b), edge.to_id);
        try testing.expectEqualStrings("CONNECTS", edge.label);
    } else {
        try testing.expect(false); // Edge should exist
    }
}

test "Graph store - set and get node properties" {
    const allocator = testing.allocator;
    
    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    
    store.clearNodes();
    
    // Create a node
    const labels = [_][]const u8{"Person"};
    const labels_slice: [][]const u8 = @constCast(&labels);
    const node_id = try store.createNode(labels_slice);
    
    // Set properties
    try store.setNodeProperty(node_id, "name", graph_store.PropertyValue{ .String = "Alice" });
    try store.setNodeProperty(node_id, "age", graph_store.PropertyValue{ .Int = 30 });
    try store.setNodeProperty(node_id, "active", graph_store.PropertyValue{ .Bool = true });
    
    // Get and verify properties
    if (store.nodes.get(node_id)) |node| {
        if (node.properties.get("name")) |name_val| {
            try testing.expect(name_val == .String);
            try testing.expectEqualStrings("Alice", name_val.String);
        } else {
            try testing.expect(false); // Property should exist
        }
        
        if (node.properties.get("age")) |age_val| {
            try testing.expect(age_val == .Int);
            try testing.expectEqual(@as(i64, 30), age_val.Int);
        } else {
            try testing.expect(false); // Property should exist
        }
        
        if (node.properties.get("active")) |active_val| {
            try testing.expect(active_val == .Bool);
            try testing.expectEqual(true, active_val.Bool);
        } else {
            try testing.expect(false); // Property should exist
        }
    }
}

test "Graph store - get outgoing edges" {
    const allocator = testing.allocator;
    
    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    
    store.clearNodes();
    
    // Create a star pattern: center connected to three spokes
    const center_labels = [_][]const u8{"Center"};
    const spoke_labels = [_][]const u8{"Spoke"};
    
    const center_slice: [][]const u8 = @constCast(&center_labels);
    const spoke_slice: [][]const u8 = @constCast(&spoke_labels);
    const center = try store.createNode(center_slice);
    const spoke1 = try store.createNode(spoke_slice);
    const spoke2 = try store.createNode(spoke_slice);
    const spoke3 = try store.createNode(spoke_slice);
    
    // Create edges from center to spokes
    _ = try store.createEdge(center, spoke1, "CONNECTS");
    _ = try store.createEdge(center, spoke2, "CONNECTS");
    _ = try store.createEdge(center, spoke3, "CONNECTS");
    
    // Get outgoing edges from center
    const outgoing = store.getEdgesFrom(center);
    defer allocator.free(outgoing);
    
    // Should have 3 outgoing edges
    try testing.expectEqual(@as(usize, 3), outgoing.len);
    
    // Verify all edges are from center
    for (outgoing) |edge| {
        try testing.expectEqual(@as(u64, center), edge.from_id);
        try testing.expectEqualStrings("CONNECTS", edge.label);
    }
}

test "Graph store - clear nodes" {
    const allocator = testing.allocator;
    
    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    
    // Create some nodes
    const labels = [_][]const u8{"Test"};
    const labels_slice: [][]const u8 = @constCast(&labels);
    _ = try store.createNode(labels_slice);
    _ = try store.createNode(labels_slice);
    _ = try store.createNode(labels_slice);
    
    // Verify nodes exist
    try testing.expect(store.nodes.count() > 0);
    
    // Clear nodes
    store.clearNodes();
    
    // Verify nodes are cleared
    try testing.expectEqual(@as(u32, 0), store.nodes.count());
    try testing.expectEqual(@as(u64, 1), store.next_node_id);
}

test "Graph store - count edges for degree calculation" {
    const allocator = testing.allocator;
    
    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    
    store.clearNodes();
    
    // Create a triangle graph
    const labels = [_][]const u8{"Node"};
    const labels_slice: [][]const u8 = @constCast(&labels);
    const node_a = try store.createNode(labels_slice);
    const node_b = try store.createNode(labels_slice);
    const node_c = try store.createNode(labels_slice);
    
    // Create edges to form a triangle
    _ = try store.createEdge(node_a, node_b, "EDGE");
    _ = try store.createEdge(node_b, node_c, "EDGE");
    _ = try store.createEdge(node_c, node_a, "EDGE");
    
    // Count edges for each node (for degree centrality)
    var degrees = std.AutoHashMap(u64, u32).init(allocator);
    defer degrees.deinit();
    
    var edge_iter = store.edges.iterator();
    while (edge_iter.next()) |entry| {
        const edge = entry.value_ptr.*;
        
        // Count for source node
        const from_count = degrees.get(edge.from_id) orelse 0;
        try degrees.put(edge.from_id, from_count + 1);
        
        // Count for target node (undirected)
        const to_count = degrees.get(edge.to_id) orelse 0;
        try degrees.put(edge.to_id, to_count + 1);
    }
    
    // Each node should have degree 2 in the triangle
    try testing.expectEqual(@as(u32, 2), degrees.get(node_a).?);
    try testing.expectEqual(@as(u32, 2), degrees.get(node_b).?);
    try testing.expectEqual(@as(u32, 2), degrees.get(node_c).?);
}