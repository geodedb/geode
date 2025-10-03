const std = @import("std");

// Shared types between graph execution and index optimization
// This module contains types that are used by both exec.zig and index_optimizer.zig
// to avoid circular dependencies.

pub const NodeId = u64;
pub const EdgeId = u64;

// Property value stored in the graph
pub const PropertyValue = union(enum) {
    Null,
    Bool: bool,
    Int: i64,
    String: []const u8,
    Decimal: struct { coeff: i128, scale: u8 },
};

// Node in the property graph
pub const Node = struct {
    id: NodeId,
    labels: []const []const u8,
    properties: std.StringHashMap(PropertyValue),
};

// Edge in the property graph
pub const Edge = struct {
    id: EdgeId,
    source: NodeId,
    target: NodeId,
    edge_type: []const u8,
    properties: std.StringHashMap(PropertyValue),
};

// Variable binding in query execution
pub const Binding = struct {
    name: []const u8,
    value: BindingValue,
    // Map of variable names to their bound values
    vars: std.StringHashMap(BindingValue),

    pub fn init(allocator: std.mem.Allocator) Binding {
        return .{
            .name = "",
            .value = .Null,
            .vars = std.StringHashMap(BindingValue).init(allocator),
        };
    }

    pub fn deinit(self: *Binding) void {
        self.vars.deinit();
    }

    pub fn clone(self: *const Binding, allocator: std.mem.Allocator) !Binding {
        var new_binding = Binding.init(allocator);
        new_binding.name = self.name;
        new_binding.value = self.value;

        // Clone the vars map
        var iter = self.vars.iterator();
        while (iter.next()) |entry| {
            try new_binding.vars.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        return new_binding;
    }
};

// Value that can be bound to a variable
pub const BindingValue = union(enum) {
    Null,
    Node: Node,
    Edge: Edge,
    Property: PropertyValue,
    Path: []const Edge,
    Value: PropertyValue,
};

// Graph storage interface (forward declaration)
pub const GraphStorage = struct {
    nodes: std.AutoHashMap(NodeId, Node),
    edges: std.ArrayList(Edge),
    // Adjacency lists for efficient traversal
    outgoing: std.AutoHashMap(NodeId, std.ArrayList(EdgeId)),
    incoming: std.AutoHashMap(NodeId, std.ArrayList(EdgeId)),
    // Optional CSR adjacency (outgoing)
    csr: ?*const anyopaque = null, // Will be cast to CSRAdjacency when needed

    pub fn init(allocator: std.mem.Allocator) GraphStorage {
        return .{
            .nodes = std.AutoHashMap(NodeId, Node).init(allocator),
            .edges = std.ArrayList(Edge).initCapacity(allocator, 0) catch unreachable,
            .outgoing = std.AutoHashMap(NodeId, std.ArrayList(EdgeId)).init(allocator),
            .incoming = std.AutoHashMap(NodeId, std.ArrayList(EdgeId)).init(allocator),
            .csr = null,
        };
    }

    pub fn deinit(self: *GraphStorage) void {
        self.nodes.deinit();
        self.edges.deinit();

        var outgoing_iter = self.outgoing.iterator();
        while (outgoing_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.outgoing.deinit();

        var incoming_iter = self.incoming.iterator();
        while (incoming_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.incoming.deinit();
    }

    // Add a node to the graph
    pub fn addNode(self: *GraphStorage, allocator: std.mem.Allocator, id: NodeId, labels: []const []const u8) !void {
        const props = std.StringHashMap(PropertyValue).init(allocator);
        try self.nodes.put(id, .{
            .id = id,
            .labels = labels,
            .properties = props,
        });
    }

    // Add an edge to the graph
    pub fn addEdge(self: *GraphStorage, allocator: std.mem.Allocator, source: NodeId, target: NodeId, edge_type: []const u8) !EdgeId {
        const edge_id = self.edges.items.len;
        const props = std.StringHashMap(PropertyValue).init(allocator);
        try self.edges.append(allocator, .{
            .id = edge_id,
            .source = source,
            .target = target,
            .edge_type = edge_type,
            .properties = props,
        });

        // Update adjacency lists
        var result = self.outgoing.getOrPut(source) catch unreachable;
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(EdgeId).initCapacity(allocator, 0) catch unreachable;
        }
        try result.value_ptr.append(allocator, edge_id);

        var target_result = self.incoming.getOrPut(target) catch unreachable;
        if (!target_result.found_existing) {
            target_result.value_ptr.* = std.ArrayList(EdgeId).initCapacity(allocator, 0) catch unreachable;
        }
        try target_result.value_ptr.append(allocator, edge_id);

        return edge_id;
    }

    // Get outgoing edges for a node
    pub fn getOutgoing(self: *const GraphStorage, node_id: NodeId) ?[]const EdgeId {
        const edges = self.outgoing.get(node_id) orelse return null;
        return edges.items;
    }

    // Get incoming edges for a node
    pub fn getIncoming(self: *const GraphStorage, node_id: NodeId) ?[]const EdgeId {
        const edges = self.incoming.get(node_id) orelse return null;
        return edges.items;
    }

    // Get all nodes in the graph
    pub fn getAllNodes(self: *const GraphStorage) std.AutoHashMap(NodeId, Node).Iterator {
        return self.nodes.iterator();
    }

    // Set a property on a node
    pub fn setNodeProperty(self: *GraphStorage, node_id: NodeId, key: []const u8, value: PropertyValue) !void {
        if (self.nodes.getPtr(node_id)) |node| {
            try node.properties.put(key, value);
        } else {
            return error.NodeNotFound;
        }
    }

    // Get a property from a node
    pub fn getNodeProperty(self: *const GraphStorage, node_id: NodeId, key: []const u8) ?PropertyValue {
        if (self.nodes.get(node_id)) |node| {
            return node.properties.get(key);
        }
        return null;
    }

    // Set a property on an edge
    pub fn setEdgeProperty(self: *GraphStorage, edge_id: EdgeId, key: []const u8, value: PropertyValue) !void {
        if (edge_id < self.edges.items.len) {
            try self.edges.items[edge_id].properties.put(key, value);
        } else {
            return error.EdgeNotFound;
        }
    }

    // Get a property from an edge
    pub fn getEdgeProperty(self: *const GraphStorage, edge_id: EdgeId, key: []const u8) ?PropertyValue {
        if (edge_id < self.edges.items.len) {
            return self.edges.items[edge_id].properties.get(key);
        }
        return null;
    }

    // Remove a property from a node
    pub fn removeNodeProperty(self: *GraphStorage, node_id: NodeId, key: []const u8) !void {
        if (self.nodes.getPtr(node_id)) |node| {
            _ = node.properties.remove(key);
        } else {
            return error.NodeNotFound;
        }
    }

    // Remove a property from an edge
    pub fn removeEdgeProperty(self: *GraphStorage, edge_id: EdgeId, key: []const u8) !void {
        if (edge_id < self.edges.items.len) {
            _ = self.edges.items[edge_id].properties.remove(key);
        } else {
            return error.EdgeNotFound;
        }
    }
};

// Index optimization types
pub const ScanType = union(enum) {
    sequential,
    index: IndexInfo,
};

pub const ScanPlan = struct {
    type: ScanType,
    estimated_cost: f64,
    estimated_rows: u64,
    // EXPLAIN output information
    explain_info: ?ExplainInfo = null,
};

pub const ExplainInfo = struct {
    operation: []const u8,
    details: []const u8,
    cost_breakdown: []const CostComponent = &.{},
    index_usage: ?IndexUsageInfo = null,
};

pub const CostComponent = struct {
    component: []const u8,
    cost: f64,
    description: []const u8,
};

pub const IndexUsageInfo = struct {
    index_name: []const u8,
    index_type: []const u8,
    properties: []const []const u8,
    selectivity: f64,
    reason: []const u8, // Why this index was chosen
};

pub const IndexInfo = struct {
    name: []const u8,
    property: []const u8,
    index_type: IndexType,
    selectivity: f64,
    label: []const u8,
    // Support for composite indexes
    properties: []const []const u8 = &.{}, // Multiple properties for composite indexes
    is_composite: bool = false,
};

pub const IndexType = enum {
    btree,
    hash,
    spatial,
    fulltext,
};

// Options for MATCH execution
pub const MatchOptions = struct {
    max_results: ?usize = null,
    max_frontier: ?usize = null,
    unique_nodes: ?bool = null,
    order_deterministic: ?bool = null,
    max_hops_limit: ?u8 = null,
    min_hops: ?u32 = null,
    timeout_ms: ?u32 = null,
};
