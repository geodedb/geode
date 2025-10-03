const std = @import("std");
const Allocator = std.mem.Allocator;
const geode = @import("geode");
const ast = geode.ast;
const graph_common = geode.graph_common;
const index_manager = geode.index.IndexManager;

// Import types from common module
const PropertyValue = graph_common.PropertyValue;
const GraphStorage = graph_common.GraphStorage;
const Binding = graph_common.Binding;
const ScanPlan = graph_common.ScanPlan;
const ScanType = graph_common.ScanType;
const IndexInfo = graph_common.IndexInfo;
const IndexType = graph_common.IndexType;

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
        prop_val: ?PropertyValue,
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
        graph: *const GraphStorage,
        plan: ScanPlan,
        labels: []const []const u8,
        var_name: ?[]const u8,
        prop_key: ?[]const u8,
        prop_val: ?PropertyValue,
    ) ![]Binding {
        switch (plan.type) {
            .sequential => {
                // Use sequential scan implementation
                return self.executeSequentialScan(graph, labels, var_name, prop_key, prop_val);
            },
            .index => |index_info| {
                // Use index scan
                return self.executeIndexScan(graph, index_info, labels, var_name, prop_key, prop_val);
            },
        }
    }

    // Execute sequential scan
    fn executeSequentialScan(
        self: *IndexOptimizer,
        graph: *const GraphStorage,
        labels: []const []const u8,
        var_name: ?[]const u8,
        prop_key: ?[]const u8,
        prop_val: ?PropertyValue,
    ) ![]Binding {
        var results = std.ArrayList(Binding).initCapacity(self.allocator, 0) catch unreachable;

        var iter = graph.nodes.iterator();
        while (iter.next()) |entry| {
            const node = entry.value_ptr.*;

            // Check if node matches any of the required labels
            if (labels.len > 0) {
                var has_label = false;
                for (labels) |required_label| {
                    for (node.labels) |node_label| {
                        if (std.mem.eql(u8, required_label, node_label)) {
                            has_label = true;
                            break;
                        }
                    }
                    if (has_label) break;
                }
                if (!has_label) continue;
            }

            // Check property filter if specified
            if (prop_key) |key| {
                if (prop_val) |val| {
                    const node_prop_val = node.properties.get(key) orelse continue;
                    if (!self.propertyValuesEqual(node_prop_val, val)) continue;
                }
            }

            // Create binding
            var binding = Binding.init(self.allocator);
            binding.name = var_name orelse "n";
            binding.value = .{ .Node = node };
            // Add the node to the vars map
            try binding.vars.put(var_name orelse "n", .{ .Node = node });

            try results.append(self.allocator, binding);
        }

        return results.toOwnedSlice();
    }

    // Execute index scan
    fn executeIndexScan(
        self: *IndexOptimizer,
        graph: *const GraphStorage,
        index_info: IndexInfo,
        labels: []const []const u8,
        var_name: ?[]const u8,
        prop_key: ?[]const u8,
        prop_val: ?PropertyValue,
    ) ![]Binding {
        var results = std.ArrayList(Binding).initCapacity(self.allocator, 0) catch unreachable;
        defer results.deinit(self.allocator);

        // Convert property value to search key
        const search_key = try self.propertyValueToIndexKey(prop_val.?);
        defer self.allocator.free(search_key);

        // Search the index
        if (try self.index_manager.lookupPropertyIndex(index_info.name, search_key)) |node_id| {
            if (graph.nodes.get(node_id)) |node| {
                // Verify node matches all criteria (labels, property value)
                if (self.nodeMatchesCriteria(node, labels, prop_key, prop_val)) {
                    var binding = Binding.init(self.allocator);
                    binding.name = var_name orelse "n";
                    binding.value = .{ .Node = node };
                    try binding.vars.put(var_name orelse "n", .{ .Node = node });
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

    fn estimateIndexScanCost(self: *IndexOptimizer, index_info: IndexInfo, prop_val: PropertyValue) f64 {
        _ = self;
        _ = prop_val;
        // Index scan cost is typically much lower than sequential scan
        return 10.0 * index_info.selectivity; // Simplified cost model
    }

    fn estimateIndexScanRows(self: *IndexOptimizer, index_info: IndexInfo, prop_val: PropertyValue) u64 {
        _ = self;
        _ = prop_val;
        // Estimated rows returned by index scan
        return @intFromFloat(1000.0 * index_info.selectivity);
    }

    // Helper functions
    fn propertyValueToIndexKey(self: *IndexOptimizer, value: PropertyValue) ![]u8 {
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
        node: graph_common.Node,
        labels: []const []const u8,
        prop_key: ?[]const u8,
        prop_val: ?PropertyValue,
    ) bool {

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
                    return self.propertyValuesEqual(actual_val, expected_val);
                } else {
                    return false;
                }
            }
        }

        return true;
    }

    // Helper function to compare property values
    fn propertyValuesEqual(self: *IndexOptimizer, a: PropertyValue, b: PropertyValue) bool {
        _ = self;
        return switch (a) {
            .Null => b == .Null,
            .Bool => |av| b == .Bool and b.Bool == av,
            .Int => |ai| b == .Int and b.Int == ai,
            .String => |as| b == .String and std.mem.eql(u8, as, b.String),
            .Decimal => |ad| b == .Decimal and ad.coeff == b.Decimal.coeff and ad.scale == b.Decimal.scale,
        };
    }
};
