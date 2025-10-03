const std = @import("std");
const Allocator = std.mem.Allocator;
const geode = @import("geode");
const ast = geode.ast;
const graph_exec = @import("graph/exec.zig");
const index_manager = geode.index.IndexManager;

// Global index optimizer instance (thread-local)
var g_index_optimizer: ?*IndexOptimizer = null;

// Set global index optimizer
pub fn setGlobalOptimizer(optimizer: *IndexOptimizer) void {
    g_index_optimizer = optimizer;
}

// Get global index optimizer
pub fn getGlobalOptimizer() ?*IndexOptimizer {
    return g_index_optimizer;
}

// Index-aware query optimizer for graph patterns
pub const IndexOptimizer = struct {
    allocator: Allocator,
    index_manager: *index_manager,
    
    pub fn init(allocator: Allocator, idx_mgr: *index_manager) IndexOptimizer {
        return IndexOptimizer{
            .allocator = allocator,
            .index_manager = idx_mgr,
        };
    }
    
    // Optimize a node scan by choosing between sequential scan and index scan
    pub fn optimizeNodeScan(
        self: *IndexOptimizer,
        labels: []const []const u8,
        _: ?[]const u8,
        prop_key: ?[]const u8,
        prop_val: ?graph_exec.PropertyValue,
    ) ScanPlan {
        // If no property filter, must use sequential scan
        if (prop_key == null or prop_val == null) {
            return ScanPlan{
                .type = .sequential,
                .estimated_cost = self.estimateSequentialScanCost(labels),
                .estimated_rows = self.estimateSequentialScanRows(labels),
            };
        }
        
        // Check if there's a suitable index for this property scan
        const property = prop_key.?;
        var best_plan = ScanPlan{
            .type = .sequential,
            .estimated_cost = self.estimateSequentialScanCost(labels),
            .estimated_rows = self.estimateSequentialScanRows(labels),
        };
        
        // Check each label for available indexes
        for (labels) |label| {
            if (self.findBestIndexForProperty(label, property)) |index_info| {
                const index_cost = self.estimateIndexScanCost(index_info, prop_val.?);
                const index_rows = self.estimateIndexScanRows(index_info, prop_val.?);
                
                if (index_cost < best_plan.estimated_cost) {
                    best_plan = ScanPlan{
                        .type = .{ .index = index_info },
                        .estimated_cost = index_cost,
                        .estimated_rows = index_rows,
                    };
                }
            }
        }
        
        return best_plan;
    }
    
    // Execute optimized scan plan
    pub fn executeOptimizedScan(
        self: *IndexOptimizer,
        graph: *const graph_exec.GraphStorage,
        plan: ScanPlan,
        labels: []const []const u8,
        var_name: ?[]const u8,
        prop_key: ?[]const u8,
        prop_val: ?graph_exec.PropertyValue,
    ) ![]graph_exec.Binding {
        switch (plan.type) {
            .sequential => {
                // Use original sequential scan
                return graph_exec.nodeScan(self.allocator, graph, labels, var_name, prop_key, prop_val);
            },
            .index => |index_info| {
                // Use index scan
                return self.executeIndexScan(graph, index_info, labels, var_name, prop_key, prop_val);
            },
        }
    }
    
    // Execute index scan
    fn executeIndexScan(
        self: *IndexOptimizer,
        graph: *const graph_exec.GraphStorage,
        index_info: IndexInfo,
        labels: []const []const u8,
        var_name: ?[]const u8,
        prop_key: ?[]const u8,
        prop_val: ?graph_exec.PropertyValue,
    ) ![]graph_exec.Binding {
        var results = std.ArrayList(graph_exec.Binding).initCapacity(self.allocator, 0) catch unreachable;
        defer results.deinit(self.allocator);
        
        // Convert property value to search key
        const search_key = try self.propertyValueToIndexKey(prop_val.?);
        defer self.allocator.free(search_key);
        
        // Search the index
        if (try self.index_manager.lookupPropertyIndex(index_info.name, search_key)) |node_id| {
            if (graph.nodes.get(node_id)) |node| {
                // Verify node matches all criteria (labels, property value)
                if (self.nodeMatchesCriteria(node, labels, prop_key, prop_val)) {
                    var binding = graph_exec.Binding.init(self.allocator);
                    if (var_name) |name| {
                        try binding.vars.put(name, .{ .Node = node_id });
                    }
                    try results.append(self.allocator, binding);
                }
            }
        }
        
        return results.toOwnedSlice(self.allocator);
    }
    
    // Find the best index for a given label and property
    fn findBestIndexForProperty(
        self: *IndexOptimizer,
        label: []const u8,
        property: []const u8,
    ) ?IndexInfo {
        // Check if we have an index for this label+property combination
        var index_name_buf: [256]u8 = undefined;
        const index_name = std.fmt.bufPrint(&index_name_buf, "{s}_{s}_idx", .{ label, property }) catch return null;
        
        if (self.index_manager.property_indexes.contains(index_name)) {
            return IndexInfo{
                .name = self.allocator.dupe(u8, index_name) catch return null,
                .label = label,
                .property = property,
                .index_type = .btree, // Assume B-tree for property equality
                .selectivity = 0.1, // Estimated selectivity
            };
        }
        
        return null;
    }
    
    // Cost estimation functions
    fn estimateSequentialScanCost(self: *IndexOptimizer, labels: []const []const u8) f64 {
        _ = self;
        _ = labels;
        // Base cost for scanning all nodes
        return 100.0; // Simplified cost model
    }
    
    fn estimateSequentialScanRows(self: *IndexOptimizer, labels: []const []const u8) u64 {
        _ = self;
        _ = labels;
        // Estimated number of rows for sequential scan
        return 1000; // Simplified estimation
    }
    
    fn estimateIndexScanCost(self: *IndexOptimizer, index_info: IndexInfo, prop_val: graph_exec.PropertyValue) f64 {
        _ = self;
        _ = prop_val;
        // Index scan cost is typically much lower than sequential scan
        return 10.0 * index_info.selectivity; // Simplified cost model
    }
    
    fn estimateIndexScanRows(self: *IndexOptimizer, index_info: IndexInfo, prop_val: graph_exec.PropertyValue) u64 {
        _ = self;
        _ = prop_val;
        // Estimated rows returned by index scan
        return @intFromFloat(1000.0 * index_info.selectivity);
    }
    
    // Helper functions
    fn propertyValueToIndexKey(self: *IndexOptimizer, value: graph_exec.PropertyValue) ![]u8 {
        return switch (value) {
            .String => |s| self.allocator.dupe(u8, s),
            .Int => |i| std.fmt.allocPrint(self.allocator, "{d}", .{i}),
            .Bool => |b| self.allocator.dupe(u8, if (b) "true" else "false"),
            .Null => self.allocator.dupe(u8, "null"),
            .Decimal => |d| std.fmt.allocPrint(self.allocator, "{d}", .{d.coeff}),
        };
    }
    
    fn nodeMatchesCriteria(
        self: *IndexOptimizer,
        node: graph_exec.Node,
        labels: []const []const u8,
        prop_key: ?[]const u8,
        prop_val: ?graph_exec.PropertyValue,
    ) bool {
        _ = self;
        
        // Check labels
        if (labels.len > 0) {
            var matches = false;
            for (labels) |required_label| {
                for (node.labels) |node_label| {
                    if (std.mem.eql(u8, required_label, node_label)) {
                        matches = true;
                        break;
                    }
                }
                if (matches) break;
            }
            if (!matches) return false;
        }
        
        // Check property
        if (prop_key) |key| {
            if (prop_val) |expected_val| {
                if (node.properties.get(key)) |actual_val| {
                    return graph_exec.propertyEquals(actual_val, expected_val);
                } else {
                    return false;
                }
            }
        }
        
        return true;
    }
};

// Scan plan types
pub const ScanPlan = struct {
    type: ScanType,
    estimated_cost: f64,
    estimated_rows: u64,
};

pub const ScanType = union(enum) {
    sequential: void,
    index: IndexInfo,
};

pub const IndexInfo = struct {
    name: []const u8,
    label: []const u8,
    property: []const u8,
    index_type: IndexType,
    selectivity: f64,
};

pub const IndexType = enum {
    btree,
    hash,
    fulltext,
    spatial,
    vector,
    hnsw,
    rtree,
    patricia,
    cryptographic,
};