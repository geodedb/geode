const std = @import("std");
const graph_store = @import("../graph_store.zig");

// Shared types between graph execution and index optimization
// This module contains types that are used by both exec.zig and index_optimizer.zig
// to avoid circular dependencies.

pub const NodeId = u64;
pub const EdgeId = u64;

// Storage-backed graph types
pub const PropertyValue = graph_store.PropertyValue;
pub const Node = graph_store.Node;
pub const Edge = graph_store.Edge;
pub const GraphStorage = graph_store.GraphStore;

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
