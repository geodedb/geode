const std = @import("std");
const graph_store = @import("graph_store.zig");

const Node = graph_store.Node;
const Edge = graph_store.Edge;
const PropertyValue = graph_store.PropertyValue;

// CANARY: REQ=REQ-MULTI-GRAPH-HANDLE-001; FEATURE="PerGraphDataIsolation"; ASPECT=GraphHandle; STATUS=IMPL; OWNER=storage; UPDATED=2026-03-16

/// Per-graph data container holding nodes, edges, and indexes for a single graph.
/// Each GraphHandle owns all memory for its data and frees it on deinit.
pub const GraphHandle = struct {
    allocator: std.mem.Allocator,
    uuid: [16]u8,
    name: []const u8,
    dirty: bool = false,
    available: bool = true,
    nodes: std.AutoHashMap(u64, Node),
    edges: std.AutoHashMap(u64, Edge),
    label_index: std.StringHashMap(std.ArrayList(u64)),
    outgoing_edges: std.AutoHashMap(u64, std.ArrayList(u64)),
    incoming_edges: std.AutoHashMap(u64, std.ArrayList(u64)),
    rwlock: std.Thread.RwLock = .{},

    /// Heap-allocate and initialize a new GraphHandle.
    /// The name is duped and owned by the handle.
    pub fn init(allocator: std.mem.Allocator, name: []const u8, graph_uuid: [16]u8) !*GraphHandle {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);

        const self = try allocator.create(GraphHandle);
        self.* = .{
            .allocator = allocator,
            .uuid = graph_uuid,
            .name = owned_name,
            .nodes = std.AutoHashMap(u64, Node).init(allocator),
            .edges = std.AutoHashMap(u64, Edge).init(allocator),
            .label_index = std.StringHashMap(std.ArrayList(u64)).init(allocator),
            .outgoing_edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
            .incoming_edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
        };
        return self;
    }

    /// Free all owned data and destroy the handle.
    pub fn deinit(self: *GraphHandle) void {
        const allocator = self.allocator;

        // Free label_index: owned key strings and ArrayList values
        var label_iter = self.label_index.iterator();
        while (label_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.label_index.deinit();

        // Free outgoing adjacency lists
        var out_iter = self.outgoing_edges.iterator();
        while (out_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.outgoing_edges.deinit();

        // Free incoming adjacency lists
        var in_iter = self.incoming_edges.iterator();
        while (in_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.incoming_edges.deinit();

        // Free nodes: labels, properties, graph_name
        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            freeNode(allocator, entry.value_ptr);
        }
        self.nodes.deinit();

        // Free edges: label, properties, graph_name
        var edge_iter = self.edges.iterator();
        while (edge_iter.next()) |entry| {
            freeEdge(allocator, entry.value_ptr);
        }
        self.edges.deinit();

        // Free owned name and destroy self
        allocator.free(self.name);
        allocator.destroy(self);
    }

    /// Return the number of nodes in this graph.
    pub fn nodeCount(self: *const GraphHandle) u64 {
        return @intCast(self.nodes.count());
    }

    /// Return the number of edges in this graph.
    pub fn edgeCount(self: *const GraphHandle) u64 {
        return @intCast(self.edges.count());
    }

    /// Clear and rebuild label_index, outgoing_edges, and incoming_edges
    /// from the current nodes and edges.
    pub fn rebuildIndexes(self: *GraphHandle) !void {
        const allocator = self.allocator;

        // Clear label_index
        var label_iter = self.label_index.iterator();
        while (label_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.label_index.deinit();
        self.label_index = std.StringHashMap(std.ArrayList(u64)).init(allocator);

        // Clear outgoing_edges
        var out_iter = self.outgoing_edges.iterator();
        while (out_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.outgoing_edges.deinit();
        self.outgoing_edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator);

        // Clear incoming_edges
        var in_iter = self.incoming_edges.iterator();
        while (in_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.incoming_edges.deinit();
        self.incoming_edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator);

        // Rebuild label_index from nodes
        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr;
            for (node.labels) |label| {
                try self.addToLabelIndex(label, node.id);
            }
        }

        // Rebuild adjacency indexes from edges
        var edge_iter = self.edges.iterator();
        while (edge_iter.next()) |entry| {
            const edge = entry.value_ptr;
            try self.addToAdjacencyIndex(&self.outgoing_edges, edge.from_id, edge.id);
            try self.addToAdjacencyIndex(&self.incoming_edges, edge.to_id, edge.id);
        }
    }

    /// Look up node IDs by label. Returns null if label not found.
    pub fn getNodesByLabel(self: *const GraphHandle, label: []const u8) ?[]const u64 {
        if (self.label_index.get(label)) |list| {
            return list.items;
        }
        return null;
    }

    // --- Internal helpers ---

    fn addToLabelIndex(self: *GraphHandle, label: []const u8, node_id: u64) !void {
        const result = try self.label_index.getOrPut(label);
        if (!result.found_existing) {
            // Allocate owned copy of the label string for the map key
            result.key_ptr.* = try self.allocator.dupe(u8, label);
            result.value_ptr.* = std.ArrayList(u64).empty;
        }
        try result.value_ptr.append(self.allocator, node_id);
    }

    fn addToAdjacencyIndex(self: *GraphHandle, map: *std.AutoHashMap(u64, std.ArrayList(u64)), key: u64, edge_id: u64) !void {
        const result = try map.getOrPut(key);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(u64).empty;
        }
        try result.value_ptr.append(self.allocator, edge_id);
    }

    fn freeNode(allocator: std.mem.Allocator, node: *Node) void {
        // Free each label string
        for (node.labels) |label| {
            allocator.free(label);
        }
        // Free the labels slice
        allocator.free(node.labels);

        // Free graph_name if not the default pointer
        if (node.graph_name.ptr != graph_store.DEFAULT_GRAPH_NAME.ptr) {
            if (node.graph_name.len > 0) {
                allocator.free(node.graph_name);
            }
        }

        // Free property keys and String values
        var prop_iter = node.properties.iterator();
        while (prop_iter.next()) |prop_entry| {
            allocator.free(prop_entry.key_ptr.*);
            freePropertyValuePartial(allocator, prop_entry.value_ptr.*);
        }
        node.properties.deinit();
    }

    fn freeEdge(allocator: std.mem.Allocator, edge: *Edge) void {
        // Free the label
        allocator.free(edge.label);

        // Free graph_name if not the default pointer
        if (edge.graph_name.ptr != graph_store.DEFAULT_GRAPH_NAME.ptr) {
            if (edge.graph_name.len > 0) {
                allocator.free(edge.graph_name);
            }
        }

        // Free property keys and String values
        var prop_iter = edge.properties.iterator();
        while (prop_iter.next()) |prop_entry| {
            allocator.free(prop_entry.key_ptr.*);
            freePropertyValuePartial(allocator, prop_entry.value_ptr.*);
        }
        edge.properties.deinit();
    }

    /// Free String property values directly. ExtValue cleanup is deferred to Task 3
    /// when shared serialization utilities are extracted.
    fn freePropertyValuePartial(allocator: std.mem.Allocator, value: PropertyValue) void {
        switch (value) {
            .String => |s| allocator.free(s),
            // ExtValue cleanup deferred — complex union with 34+ variants
            else => {},
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "GraphHandle init/deinit" {
    const allocator = std.testing.allocator;
    const test_uuid = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 };

    const handle = try GraphHandle.init(allocator, "test_graph", test_uuid);
    defer handle.deinit();

    try std.testing.expectEqualStrings("test_graph", handle.name);
    try std.testing.expectEqual(test_uuid, handle.uuid);
    try std.testing.expect(handle.available);
    try std.testing.expect(!handle.dirty);
    try std.testing.expectEqual(@as(u64, 0), handle.nodeCount());
    try std.testing.expectEqual(@as(u64, 0), handle.edgeCount());
}

test "GraphHandle rebuildIndexes and getNodesByLabel" {
    const allocator = std.testing.allocator;
    const test_uuid = [_]u8{0} ** 16;

    const handle = try GraphHandle.init(allocator, "test", test_uuid);
    defer handle.deinit();

    // Create labels array
    const label1 = try allocator.dupe(u8, "Person");
    const label2 = try allocator.dupe(u8, "Employee");
    const labels = try allocator.alloc([]const u8, 2);
    labels[0] = label1;
    labels[1] = label2;

    var props = std.StringHashMap(PropertyValue).init(allocator);
    const name_key = try allocator.dupe(u8, "name");
    const name_val = try allocator.dupe(u8, "Alice");
    try props.put(name_key, PropertyValue{ .String = name_val });

    const graph_name = try allocator.dupe(u8, "test");

    try handle.nodes.put(1, Node{
        .id = 1,
        .labels = labels,
        .properties = props,
        .graph_name = graph_name,
    });

    // Before rebuild, label index is empty
    try std.testing.expect(handle.getNodesByLabel("Person") == null);

    // Rebuild indexes
    try handle.rebuildIndexes();

    // After rebuild, both labels should find node 1
    const person_nodes = handle.getNodesByLabel("Person").?;
    try std.testing.expectEqual(@as(usize, 1), person_nodes.len);
    try std.testing.expectEqual(@as(u64, 1), person_nodes[0]);

    const employee_nodes = handle.getNodesByLabel("Employee").?;
    try std.testing.expectEqual(@as(usize, 1), employee_nodes.len);
    try std.testing.expectEqual(@as(u64, 1), employee_nodes[0]);
}

test "GraphHandle getNodesByLabel returns null for missing label" {
    const allocator = std.testing.allocator;
    const test_uuid = [_]u8{0} ** 16;

    const handle = try GraphHandle.init(allocator, "test", test_uuid);
    defer handle.deinit();

    try std.testing.expect(handle.getNodesByLabel("NonExistent") == null);
}

test "GraphHandle rebuildIndexes builds adjacency lists" {
    const allocator = std.testing.allocator;
    const test_uuid = [_]u8{0} ** 16;

    const handle = try GraphHandle.init(allocator, "edges_test", test_uuid);
    defer handle.deinit();

    // Add two nodes (minimal — no labels)
    const empty_labels1 = try allocator.alloc([]const u8, 0);
    const gn1 = try allocator.dupe(u8, "edges_test");
    var props1 = std.StringHashMap(PropertyValue).init(allocator);
    try handle.nodes.put(10, Node{ .id = 10, .labels = empty_labels1, .properties = props1, .graph_name = gn1 });

    _ = &props1;

    const empty_labels2 = try allocator.alloc([]const u8, 0);
    const gn2 = try allocator.dupe(u8, "edges_test");
    var props2 = std.StringHashMap(PropertyValue).init(allocator);
    try handle.nodes.put(20, Node{ .id = 20, .labels = empty_labels2, .properties = props2, .graph_name = gn2 });

    _ = &props2;

    // Add an edge from node 10 to node 20
    const edge_label = try allocator.dupe(u8, "KNOWS");
    const edge_gn = try allocator.dupe(u8, "edges_test");
    var edge_props = std.StringHashMap(PropertyValue).init(allocator);
    try handle.edges.put(100, Edge{
        .id = 100,
        .from_id = 10,
        .to_id = 20,
        .label = edge_label,
        .properties = edge_props,
        .graph_name = edge_gn,
    });

    _ = &edge_props;

    // Rebuild
    try handle.rebuildIndexes();

    // Verify outgoing: node 10 -> [edge 100]
    const outgoing = handle.outgoing_edges.get(10).?;
    try std.testing.expectEqual(@as(usize, 1), outgoing.items.len);
    try std.testing.expectEqual(@as(u64, 100), outgoing.items[0]);

    // Verify incoming: node 20 -> [edge 100]
    const incoming = handle.incoming_edges.get(20).?;
    try std.testing.expectEqual(@as(usize, 1), incoming.items.len);
    try std.testing.expectEqual(@as(u64, 100), incoming.items[0]);

    // Verify counts
    try std.testing.expectEqual(@as(u64, 2), handle.nodeCount());
    try std.testing.expectEqual(@as(u64, 1), handle.edgeCount());
}
