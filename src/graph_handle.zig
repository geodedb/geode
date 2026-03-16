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

    // CANARY: REQ=REQ-MULTI-GRAPH-HANDLE-004; FEATURE="PerGraphMutations"; ASPECT=NodeMutation; STATUS=IMPL; OWNER=storage; UPDATED=2026-03-16

    /// Add a node to this handle (makes independent copies of all owned data).
    /// Updates label index and marks handle dirty.
    pub fn addNode(self: *GraphHandle, node: *const Node) !void {
        // Copy labels
        const labels_copy = try self.allocator.alloc([]const u8, node.labels.len);
        for (node.labels, 0..) |label, i| {
            labels_copy[i] = try self.allocator.dupe(u8, label);
        }
        errdefer {
            for (labels_copy) |l| self.allocator.free(l);
            self.allocator.free(labels_copy);
        }

        // Copy graph_name
        const graph_name_copy = if (node.graph_name.ptr != graph_store.DEFAULT_GRAPH_NAME.ptr)
            try self.allocator.dupe(u8, node.graph_name)
        else
            node.graph_name;
        errdefer if (graph_name_copy.ptr != graph_store.DEFAULT_GRAPH_NAME.ptr) {
            self.allocator.free(graph_name_copy);
        };

        // Copy properties
        var props_copy = std.StringHashMap(PropertyValue).init(self.allocator);
        errdefer {
            var it = props_copy.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                freePropertyValuePartial(self.allocator, entry.value_ptr.*);
            }
            props_copy.deinit();
        }
        var prop_it = node.properties.iterator();
        while (prop_it.next()) |entry| {
            const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(key_copy);
            const val_copy = try copyPropertyValueForHandle(self.allocator, entry.value_ptr.*);
            errdefer freePropertyValuePartial(self.allocator, val_copy);
            try props_copy.put(key_copy, val_copy);
        }

        const handle_node = Node{
            .id = node.id,
            .labels = labels_copy,
            .properties = props_copy,
            .graph_name = graph_name_copy,
        };

        try self.nodes.put(node.id, handle_node);

        // Update label index
        for (labels_copy) |label| {
            try self.addToLabelIndex(label, node.id);
        }

        self.dirty = true;
    }

    /// Remove a node from this handle (frees owned copies, updates indexes).
    pub fn removeNode(self: *GraphHandle, node_id: u64) void {
        if (self.nodes.fetchRemove(node_id)) |kv| {
            var node = kv.value;
            // Update label index
            for (node.labels) |label| {
                self.removeFromLabelIndex(label, node_id);
            }
            freeNode(self.allocator, &node);
        }
        self.dirty = true;
    }

    /// Add an edge to this handle (makes independent copies of owned data).
    /// Updates adjacency indexes and marks handle dirty.
    pub fn addEdge(self: *GraphHandle, edge: *const Edge) !void {
        const label_copy = try self.allocator.dupe(u8, edge.label);
        errdefer self.allocator.free(label_copy);

        const graph_name_copy = if (edge.graph_name.ptr != graph_store.DEFAULT_GRAPH_NAME.ptr)
            try self.allocator.dupe(u8, edge.graph_name)
        else
            edge.graph_name;
        errdefer if (graph_name_copy.ptr != graph_store.DEFAULT_GRAPH_NAME.ptr) {
            self.allocator.free(graph_name_copy);
        };

        // Copy properties
        var props_copy = std.StringHashMap(PropertyValue).init(self.allocator);
        errdefer {
            var it = props_copy.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                freePropertyValuePartial(self.allocator, entry.value_ptr.*);
            }
            props_copy.deinit();
        }
        var prop_it = edge.properties.iterator();
        while (prop_it.next()) |entry| {
            const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(key_copy);
            const val_copy = try copyPropertyValueForHandle(self.allocator, entry.value_ptr.*);
            errdefer freePropertyValuePartial(self.allocator, val_copy);
            try props_copy.put(key_copy, val_copy);
        }

        const handle_edge = Edge{
            .id = edge.id,
            .from_id = edge.from_id,
            .to_id = edge.to_id,
            .label = label_copy,
            .properties = props_copy,
            .graph_name = graph_name_copy,
        };

        try self.edges.put(edge.id, handle_edge);

        // Update adjacency indexes
        try self.addToAdjacencyIndex(&self.outgoing_edges, edge.from_id, edge.id);
        try self.addToAdjacencyIndex(&self.incoming_edges, edge.to_id, edge.id);

        self.dirty = true;
    }

    /// Remove an edge from this handle (frees owned copies, updates adjacency indexes).
    pub fn removeEdge(self: *GraphHandle, edge_id: u64) void {
        if (self.edges.fetchRemove(edge_id)) |kv| {
            var edge = kv.value;
            // Update adjacency indexes
            self.removeFromAdjacencyIndex(edge.from_id, edge.to_id, edge_id);
            freeEdge(self.allocator, &edge);
        }
        self.dirty = true;
    }

    /// Mark the handle dirty when a property is mutated in-place on the flat map.
    /// Called by GraphStore when node/edge properties are set or removed.
    pub fn markDirty(self: *GraphHandle) void {
        self.dirty = true;
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

    fn removeFromLabelIndex(self: *GraphHandle, label: []const u8, node_id: u64) void {
        if (self.label_index.getPtr(label)) |list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i] == node_id) {
                    _ = list.orderedRemove(i);
                    break;
                }
                i += 1;
            }
            if (list.items.len == 0) {
                if (self.label_index.fetchRemove(label)) |kv| {
                    self.allocator.free(kv.key);
                    var list_copy = kv.value;
                    list_copy.deinit(self.allocator);
                }
            }
        }
    }

    fn removeFromAdjacencyIndex(self: *GraphHandle, from_id: u64, to_id: u64, edge_id: u64) void {
        if (self.outgoing_edges.getPtr(from_id)) |list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i] == edge_id) {
                    _ = list.swapRemove(i);
                    break;
                }
                i += 1;
            }
        }
        if (self.incoming_edges.getPtr(to_id)) |list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i] == edge_id) {
                    _ = list.swapRemove(i);
                    break;
                }
                i += 1;
            }
        }
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

/// Copy a PropertyValue for storage in a GraphHandle.
/// Handles String (heap-allocated) and non-string (value-type) variants.
/// ExtValue copy is deferred — treated as value type for now.
fn copyPropertyValueForHandle(allocator: std.mem.Allocator, value: PropertyValue) !PropertyValue {
    return switch (value) {
        .String => |s| PropertyValue{ .String = try allocator.dupe(u8, s) },
        else => value,
    };
}

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

test "GraphHandle addNode sets dirty flag" {
    const allocator = std.testing.allocator;
    const test_uuid = [_]u8{0} ** 16;
    const handle = try GraphHandle.init(allocator, "dirty_test", test_uuid);
    defer handle.deinit();

    try std.testing.expect(!handle.dirty);

    // Build a minimal node
    const labels = try allocator.alloc([]const u8, 1);
    labels[0] = try allocator.dupe(u8, "TestLabel");
    var props = std.StringHashMap(PropertyValue).init(allocator);
    const key = try allocator.dupe(u8, "k");
    try props.put(key, PropertyValue{ .String = try allocator.dupe(u8, "v") });
    const gn = try allocator.dupe(u8, "dirty_test");

    var node = Node{ .id = 1, .labels = labels, .properties = props, .graph_name = gn };
    try handle.addNode(&node);

    try std.testing.expect(handle.dirty);
    try std.testing.expectEqual(@as(u64, 1), handle.nodeCount());

    // Free the source node data (handle made copies)
    allocator.free(gn);
    allocator.free(key);
    allocator.free(labels[0]);
    allocator.free(labels);
    var it = props.iterator();
    while (it.next()) |e| freeVal(allocator, e.value_ptr.*);
    props.deinit();
}

test "GraphHandle removeNode sets dirty flag" {
    const allocator = std.testing.allocator;
    const test_uuid = [_]u8{0} ** 16;
    const handle = try GraphHandle.init(allocator, "remove_test", test_uuid);
    defer handle.deinit();

    // Add a node via addNode
    const labels = try allocator.alloc([]const u8, 0);
    var props = std.StringHashMap(PropertyValue).init(allocator);
    const gn = try allocator.dupe(u8, "remove_test");
    var node = Node{ .id = 42, .labels = labels, .properties = props, .graph_name = gn };
    try handle.addNode(&node);
    allocator.free(gn);
    allocator.free(labels);
    props.deinit();

    // Clear dirty to test that removeNode sets it again
    handle.dirty = false;

    handle.removeNode(42);
    try std.testing.expect(handle.dirty);
    try std.testing.expectEqual(@as(u64, 0), handle.nodeCount());
}

test "GraphHandle addEdge and removeEdge track dirty" {
    const allocator = std.testing.allocator;
    const test_uuid = [_]u8{0} ** 16;
    const handle = try GraphHandle.init(allocator, "edge_dirty", test_uuid);
    defer handle.deinit();

    try std.testing.expect(!handle.dirty);

    const label = try allocator.dupe(u8, "REL");
    const gn = try allocator.dupe(u8, "edge_dirty");
    var props = std.StringHashMap(PropertyValue).init(allocator);
    var edge = Edge{ .id = 1, .from_id = 10, .to_id = 20, .label = label, .properties = props, .graph_name = gn };
    try handle.addEdge(&edge);
    allocator.free(label);
    allocator.free(gn);
    props.deinit();

    try std.testing.expect(handle.dirty);
    try std.testing.expectEqual(@as(u64, 1), handle.edgeCount());

    handle.dirty = false;
    handle.removeEdge(1);
    try std.testing.expect(handle.dirty);
    try std.testing.expectEqual(@as(u64, 0), handle.edgeCount());
}

fn freeVal(allocator: std.mem.Allocator, val: PropertyValue) void {
    switch (val) {
        .String => |s| allocator.free(s),
        else => {},
    }
}
