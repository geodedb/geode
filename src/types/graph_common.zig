const std = @import("std");
const audit = @import("../security/audit.zig");

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
    VectorF32: VectorF32,
};

// Vector type for PropertyValue
pub const VectorF32 = struct {
    dim: u16,
    data: []const f32,
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
    Node: *Node,
    Edge: *Edge,
    Property: PropertyValue,
    Path: []const Edge,
    Value: PropertyValue,
};

// Graph storage interface (forward declaration)
pub const GraphStorage = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMap(NodeId, Node),
    edges: std.ArrayList(Edge),
    // Adjacency lists for efficient traversal
    outgoing: std.AutoHashMap(NodeId, std.ArrayList(EdgeId)),
    incoming: std.AutoHashMap(NodeId, std.ArrayList(EdgeId)),
    // Optional CSR adjacency (outgoing)
    csr: ?*const anyopaque = null, // Will be cast to CSRAdjacency when needed
    audit_logger: ?*audit.AuditLogger,

    pub fn init(allocator: std.mem.Allocator, logger: ?*audit.AuditLogger) GraphStorage {
        return .{
            .allocator = allocator,
            .nodes = std.AutoHashMap(NodeId, Node).init(allocator),
            .edges = std.ArrayList(Edge).initCapacity(allocator, 0) catch unreachable,
            .outgoing = std.AutoHashMap(NodeId, std.ArrayList(EdgeId)).init(allocator),
            .incoming = std.AutoHashMap(NodeId, std.ArrayList(EdgeId)).init(allocator),
            .csr = null,
            .audit_logger = logger,
        };
    }

    pub fn deinit(self: *GraphStorage) void {
        const allocator = self.allocator;
        self.nodes.deinit();
        self.edges.deinit(allocator);

        var outgoing_iter = self.outgoing.iterator();
        while (outgoing_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.outgoing.deinit();

        var incoming_iter = self.incoming.iterator();
        while (incoming_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.incoming.deinit();
    }

    // Add a node to the graph
    pub fn addNode(self: *GraphStorage, allocator: std.mem.Allocator, id: NodeId, labels: []const []const u8) !void {
        const props = std.StringHashMap(PropertyValue).init(allocator);

        // Deep copy labels to ensure they remain valid after AST is freed
        var owned_labels = try allocator.alloc([]const u8, labels.len);
        for (labels, 0..) |label, i| {
            owned_labels[i] = try allocator.dupe(u8, label);
        }

        try self.nodes.put(id, .{
            .id = id,
            .labels = owned_labels,
            .properties = props,
        });

        if (self.audit_logger) |logger| {
            var details = std.StringHashMap([]const u8).init(allocator);
            // Construct label string
            if (labels.len > 0) {
                var buf = std.ArrayList(u8).initCapacity(allocator, 64) catch unreachable;
                defer buf.deinit(allocator);
                for (labels, 0..) |l, i| {
                    if (i > 0) buf.appendSlice(allocator, ",") catch {};
                    buf.appendSlice(allocator, l) catch {};
                }
                try details.put("labels", try allocator.dupe(u8, buf.items));
            }
            const rid = try std.fmt.allocPrint(allocator, "node:{}", .{id});
            defer allocator.free(rid);

            var ev = audit.AuditEvent{
                .timestamp = std.time.milliTimestamp(),
                .event_type = .data_modification,
                .severity = .info,
                .user_id = 0, // System user ID (GraphStorage doesn't have ctx)
                .session_id = "",
                .resource = .{ .type = "graph_node", .id = rid, .name = rid, .graph = null, .table = null },
                .action = "create",
                .result = .success,
                .details = details,
            };
            try logger.appendAuditEvent(&ev);
            var it = details.iterator();
            while (it.next()) |e| allocator.free(e.value_ptr.*);
            details.deinit();
        }
    }

    // Add an edge to the graph
    pub fn addEdge(self: *GraphStorage, allocator: std.mem.Allocator, source: NodeId, target: NodeId, edge_type: []const u8) !EdgeId {
        const edge_id = self.edges.items.len;
        const props = std.StringHashMap(PropertyValue).init(allocator);

        // Deep copy edge_type to ensure it remains valid after AST is freed
        const owned_edge_type = try allocator.dupe(u8, edge_type);

        try self.edges.append(allocator, .{
            .id = edge_id,
            .source = source,
            .target = target,
            .edge_type = owned_edge_type,
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

        if (self.audit_logger) |logger| {
            var details = std.StringHashMap([]const u8).init(allocator);
            try details.put("type", try allocator.dupe(u8, edge_type));
            const src_str = try std.fmt.allocPrint(allocator, "{}", .{source});
            defer allocator.free(src_str);
            const tgt_str = try std.fmt.allocPrint(allocator, "{}", .{target});
            defer allocator.free(tgt_str);
            try details.put("source", try allocator.dupe(u8, src_str));
            try details.put("target", try allocator.dupe(u8, tgt_str));

            const rid = try std.fmt.allocPrint(allocator, "edge:{}", .{edge_id});
            defer allocator.free(rid);

            var ev = audit.AuditEvent{
                .timestamp = std.time.milliTimestamp(),
                .event_type = .data_modification,
                .severity = .info,
                .user_id = 0, // System user ID (GraphStorage doesn't have ctx)
                .session_id = "",
                .resource = .{ .type = "graph_edge", .id = rid, .name = rid, .graph = null, .table = null },
                .action = "create",
                .result = .success,
                .details = details,
            };
            try logger.appendAuditEvent(&ev);
            var it = details.iterator();
            while (it.next()) |e| allocator.free(e.value_ptr.*);
            details.deinit();
        }

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
    pub fn setNodeProperty(self: *GraphStorage, allocator: std.mem.Allocator, node_id: NodeId, key: []const u8, value: PropertyValue) !void {
        if (self.nodes.getPtr(node_id)) |node| {
            // Deep copy the key to ensure it remains valid after AST is freed
            const owned_key = try allocator.dupe(u8, key);
            try node.properties.put(owned_key, value);

            if (self.audit_logger) |logger| {
                var details = std.StringHashMap([]const u8).init(allocator);
                try details.put("key", try allocator.dupe(u8, key));
                // Simplify value logging for now (e.g. type or short string)
                // Proper value logging might need JSON serialization of PropertyValue, but simplified is OK.
                // Value logging simplified to type for now
                // If we alloc'd val_str, we must own it or free it.
                // The switch returns either literal or alloc'd.
                // To be safe and uniform, we dupe literal or take ownership.
                // const stored_val = try allocator.dupe(u8, val_str);
                // If we alloc'd inside switch (Int, String), we leaked that intermediate buffer if we duped it again.
                // Better: just format directly into details.

                // Let's redo details putting cleanly without leak risk
                // Reset details for key/value
                // We already put 'key'.

                // For value, we just put string representation
                try details.put("value_type", try allocator.dupe(u8, @tagName(value)));

                const rid = try std.fmt.allocPrint(allocator, "node:{}", .{node_id});
                defer allocator.free(rid);

                var ev = audit.AuditEvent{
                    .timestamp = std.time.milliTimestamp(),
                    .event_type = .data_modification,
                    .severity = .info,
                    .user_id = 0, // System user ID (GraphStorage doesn't have ctx)
                    .session_id = "",
                    .resource = .{ .type = "graph_node", .id = rid, .name = rid, .graph = null, .table = null },
                    .action = "update_property",
                    .result = .success,
                    .details = details,
                };
                try logger.appendAuditEvent(&ev);

                // Cleanup
                // Clean up any extra allocs from switch cases if needed?
                // The switch cases above were hypothetical. I haven't implemented them yet.
                // The code above (lines 106-111 in original) handles property values.

                var it = details.iterator();
                while (it.next()) |e| allocator.free(e.value_ptr.*);
                details.deinit();
            }
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
    pub fn setEdgeProperty(self: *GraphStorage, allocator: std.mem.Allocator, edge_id: EdgeId, key: []const u8, value: PropertyValue) !void {
        if (edge_id < self.edges.items.len) {
            // Deep copy the key to ensure it remains valid after AST is freed
            const owned_key = try allocator.dupe(u8, key);
            try self.edges.items[edge_id].properties.put(owned_key, value);

            if (self.audit_logger) |logger| {
                var details = std.StringHashMap([]const u8).init(allocator);
                try details.put("key", try allocator.dupe(u8, key));
                try details.put("value_type", try allocator.dupe(u8, @tagName(value)));

                const rid = try std.fmt.allocPrint(allocator, "edge:{}", .{edge_id});
                defer allocator.free(rid);

                var ev = audit.AuditEvent{
                    .timestamp = std.time.milliTimestamp(),
                    .event_type = .data_modification,
                    .severity = .info,
                    .user_id = 0,
                    .session_id = "",
                    .resource = .{ .type = "graph_edge", .id = rid, .name = rid, .graph = null, .table = null },
                    .action = "update_property",
                    .result = .success,
                    .details = details,
                };
                try logger.appendAuditEvent(&ev);
                var it = details.iterator();
                while (it.next()) |e| allocator.free(e.value_ptr.*);
                details.deinit();
            }
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

            if (self.audit_logger) |logger| {
                var details = std.StringHashMap([]const u8).init(self.allocator);
                try details.put("key", try self.allocator.dupe(u8, key));
                const rid = try std.fmt.allocPrint(self.allocator, "node:{}", .{node_id});
                defer self.allocator.free(rid);
                var ev = audit.AuditEvent{
                    .timestamp = std.time.milliTimestamp(),
                    .event_type = .data_modification,
                    .severity = .info,
                    .user_id = 0,
                    .session_id = "",
                    .resource = .{ .type = "graph_node", .id = rid, .name = rid, .graph = null, .table = null },
                    .action = "delete_property",
                    .result = .success,
                    .details = details,
                };
                try logger.appendAuditEvent(&ev);
                var it = details.iterator();
                while (it.next()) |e| self.allocator.free(e.value_ptr.*);
                details.deinit();
            }
        } else {
            return error.NodeNotFound;
        }
    }

    // Remove a property from an edge
    pub fn removeEdgeProperty(self: *GraphStorage, edge_id: EdgeId, key: []const u8) !void {
        if (edge_id < self.edges.items.len) {
            _ = self.edges.items[edge_id].properties.remove(key);
            if (self.audit_logger) |logger| {
                var details = std.StringHashMap([]const u8).init(self.allocator);
                try details.put("key", try self.allocator.dupe(u8, key));
                const rid = try std.fmt.allocPrint(self.allocator, "edge:{}", .{edge_id});
                defer self.allocator.free(rid);
                var ev = audit.AuditEvent{
                    .timestamp = std.time.milliTimestamp(),
                    .event_type = .data_modification,
                    .severity = .info,
                    .user_id = 0,
                    .session_id = "",
                    .resource = .{ .type = "graph_edge", .id = rid, .name = rid, .graph = null, .table = null },
                    .action = "delete_property",
                    .result = .success,
                    .details = details,
                };
                try logger.appendAuditEvent(&ev);
                var it = details.iterator();
                while (it.next()) |e| self.allocator.free(e.value_ptr.*);
                details.deinit();
            }
        } else {
            return error.EdgeNotFound;
        }
    }

    // CANARY: REQ=REQ-TXN-UNDO-SERVER-012; FEATURE="TransactionUndoLog"; ASPECT=GraphStorageRemoveNode; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
    // Remove a node from the graph (for rollback support)
    pub fn removeNode(self: *GraphStorage, node_id: NodeId) void {
        if (self.audit_logger) |logger| {
            // simplified logging for delete
            const rid = std.fmt.allocPrint(self.allocator, "node:{}", .{node_id}) catch "unknown";
            defer if (!std.mem.eql(u8, rid, "unknown")) self.allocator.free(rid);

            var ev = audit.AuditEvent{
                .timestamp = std.time.milliTimestamp(),
                .event_type = .data_modification,
                .resource = .{ .type = "graph_node", .id = rid, .name = rid, .graph = null, .table = null },
                .action = "delete",
                .result = .success,
                .details = null,
            };
            logger.appendAuditEvent(&ev) catch {};
        }

        // Remove from adjacency lists
        if (self.outgoing.fetchRemove(node_id)) |entry| {
            entry.value.deinit(self.allocator);
        }
        if (self.incoming.fetchRemove(node_id)) |entry| {
            entry.value.deinit(self.allocator);
        }
        // Also remove references to this node from other adjacency lists
        // (edges pointing to this node)
        var out_iter = self.outgoing.iterator();
        while (out_iter.next()) |entry| {
            // Filter out edges that reference the removed node
            var i: usize = 0;
            while (i < entry.value_ptr.items.len) {
                const edge_id = entry.value_ptr.items[i];
                if (edge_id < self.edges.items.len) {
                    const edge = &self.edges.items[edge_id];
                    if (edge.target == node_id) {
                        _ = entry.value_ptr.orderedRemove(i);
                        continue;
                    }
                }
                i += 1;
            }
        }
        var in_iter = self.incoming.iterator();
        while (in_iter.next()) |entry| {
            var i: usize = 0;
            while (i < entry.value_ptr.items.len) {
                const edge_id = entry.value_ptr.items[i];
                if (edge_id < self.edges.items.len) {
                    const edge = &self.edges.items[edge_id];
                    if (edge.source == node_id) {
                        _ = entry.value_ptr.orderedRemove(i);
                        continue;
                    }
                }
                i += 1;
            }
        }
        // Remove the node itself
        _ = self.nodes.remove(node_id);
    }

    // CANARY: REQ=REQ-TXN-UNDO-SERVER-013; FEATURE="TransactionUndoLog"; ASPECT=GraphStorageRemoveEdge; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
    // Mark an edge as deleted (for rollback support) - we can't actually remove from ArrayList
    // without reindexing, so we mark it by setting source/target to max value
    pub fn removeEdge(self: *GraphStorage, edge_id: EdgeId) void {
        if (self.audit_logger) |logger| {
            const rid = std.fmt.allocPrint(self.allocator, "edge:{}", .{edge_id}) catch "unknown";
            defer if (!std.mem.eql(u8, rid, "unknown")) self.allocator.free(rid);

            var ev = audit.AuditEvent{
                .timestamp = std.time.milliTimestamp(),
                .event_type = .data_modification,
                .resource = .{ .type = "graph_edge", .id = rid, .name = rid, .graph = null, .table = null },
                .action = "delete",
                .result = .success,
                .details = null,
            };
            logger.appendAuditEvent(&ev) catch {};
        }

        if (edge_id < self.edges.items.len) {
            const edge = &self.edges.items[edge_id];
            const source = edge.source;
            const target = edge.target;
            // Mark as deleted
            edge.source = std.math.maxInt(NodeId);
            edge.target = std.math.maxInt(NodeId);
            // Remove from adjacency lists
            if (self.outgoing.getPtr(source)) |list| {
                var i: usize = 0;
                while (i < list.items.len) {
                    if (list.items[i] == edge_id) {
                        _ = list.orderedRemove(i);
                        break;
                    }
                    i += 1;
                }
            }
            if (self.incoming.getPtr(target)) |list| {
                var i: usize = 0;
                while (i < list.items.len) {
                    if (list.items[i] == edge_id) {
                        _ = list.orderedRemove(i);
                        break;
                    }
                    i += 1;
                }
            }
        }
    }
};

// Index optimization types
pub const ScanType = union(enum) {
    sequential,
    index: IndexInfo,
    vector_knn: VectorKNNInfo,
    fulltext_search: FullTextInfo,
};

pub const VectorKNNInfo = struct {
    index_name: []const u8,
    query_vector: []const f32,
    k: u32,
    metric: []const u8, // "l2", "cosine", "dot"
    property: []const u8,
};

pub const FullTextInfo = struct {
    index_name: []const u8,
    query_terms: []const []const u8,
    property: []const u8,
    analyzer: []const u8, // "simple", "standard", "english"
    max_results: u32,
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
    vector_hnsw,
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

// Column definition for query results and materialized views
pub const Column = struct {
    name: []const u8,
    type: []const u8,
};
