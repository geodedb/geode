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
        return self.optimizeNodeScanWithFilters(labels, if (prop_key) |key| &[_][]const u8{key} else &.{}, if (prop_val) |val| &[_]PropertyValue{val} else &.{});
    }

    // Enhanced optimization supporting multiple property filters (for composite indexes)
    pub fn optimizeNodeScanWithFilters(
        self: *IndexOptimizer,
        labels: []const []const u8,
        prop_keys: []const []const u8,
        prop_vals: []const PropertyValue,
    ) ScanPlan {
        // If no property filters, must use sequential scan
        if (prop_keys.len == 0 or prop_vals.len == 0 or prop_keys.len != prop_vals.len) {
            const sequential_cost = self.estimateSequentialScanCost(labels);
            const sequential_rows = self.estimateSequentialScanRows(labels);
            
            return ScanPlan{
                .type = .sequential,
                .estimated_cost = sequential_cost,
                .estimated_rows = sequential_rows,
                .explain_info = self.createSequentialScanExplain(labels, sequential_cost, sequential_rows),
            };
        }

        var best_plan = ScanPlan{
            .type = .sequential,
            .estimated_cost = self.estimateSequentialScanCost(labels),
            .estimated_rows = self.estimateSequentialScanRows(labels),
            .explain_info = null, // Will be set if sequential scan is chosen
        };

        var considered_indexes = std.ArrayList(IndexConsideration).init(self.allocator);
        defer considered_indexes.deinit();

        // Check each label for available indexes
        for (labels) |label| {
            // Try single-property indexes first
            if (prop_keys.len == 1) {
                if (self.findBestIndexForProperty(label, prop_keys[0])) |index_info| {
                    const index_cost = self.estimateIndexScanCost(index_info, prop_vals[0]);
                    const index_rows = self.estimateIndexScanRows(index_info, prop_vals[0]);

                    const consideration = IndexConsideration{
                        .index_info = index_info,
                        .cost = index_cost,
                        .rows = index_rows,
                        .chosen = index_cost < best_plan.estimated_cost,
                    };
                    considered_indexes.append(consideration) catch {};

                    if (index_cost < best_plan.estimated_cost) {
                        best_plan = ScanPlan{
                            .type = .{ .index = index_info },
                            .estimated_cost = index_cost,
                            .estimated_rows = index_rows,
                            .explain_info = self.createIndexScanExplain(index_info, index_cost, index_rows, prop_keys, false),
                        };
                    }
                }
            }
            
            // Try composite indexes for multi-property queries
            if (prop_keys.len > 1) {
                if (self.findBestCompositeIndex(label, prop_keys)) |composite_index| {
                    const composite_cost = self.estimateCompositeIndexCost(composite_index, prop_keys, prop_vals);
                    const composite_rows = self.estimateCompositeIndexRows(composite_index, prop_keys, prop_vals);

                    const consideration = IndexConsideration{
                        .index_info = composite_index,
                        .cost = composite_cost,
                        .rows = composite_rows,
                        .chosen = composite_cost < best_plan.estimated_cost,
                    };
                    considered_indexes.append(consideration) catch {};

                    if (composite_cost < best_plan.estimated_cost) {
                        best_plan = ScanPlan{
                            .type = .{ .index = composite_index },
                            .estimated_cost = composite_cost,
                            .estimated_rows = composite_rows,
                            .explain_info = self.createIndexScanExplain(composite_index, composite_cost, composite_rows, prop_keys, true),
                        };
                    }
                }
            }
        }

        // If sequential scan was chosen, create explain info with alternatives
        if (best_plan.type == .sequential) {
            best_plan.explain_info = self.createSequentialScanExplainWithAlternatives(
                labels, 
                best_plan.estimated_cost, 
                best_plan.estimated_rows, 
                considered_indexes.items
            );
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
        var best_index: ?IndexInfo = null;
        var best_cost: f64 = std.math.inf(f64);

        // Check different index types for this label+property combination
        const index_types = [_]IndexType{ .btree, .hash, .spatial, .fulltext };
        
        for (index_types) |index_type| {
            var index_name_buf: [256]u8 = undefined;
            const index_name = std.fmt.bufPrint(&index_name_buf, "{s}_{s}_{s}_idx", .{ label, property, @tagName(index_type) }) catch continue;

            if (self.index_manager.property_indexes.contains(index_name)) {
                const selectivity = self.estimateIndexSelectivity(index_type, property);
                const index_info = IndexInfo{
                    .name = self.allocator.dupe(u8, index_name) catch continue,
                    .label = label,
                    .property = property,
                    .index_type = index_type,
                    .selectivity = selectivity,
                };
                
                // Calculate cost for this index type
                const cost = self.estimateIndexTypeCost(index_type, selectivity);
                
                if (cost < best_cost) {
                    best_cost = cost;
                    best_index = index_info;
                }
            }
        }

        return best_index;
    }

    // Find the best composite index for multiple properties
    fn findBestCompositeIndex(
        self: *IndexOptimizer,
        label: []const u8,
        properties: []const []const u8,
    ) ?IndexInfo {
        var best_index: ?IndexInfo = null;
        var best_cost: f64 = std.math.inf(f64);

        // Try different combinations of properties for composite indexes
        // For now, check if there's an exact match for all properties
        var composite_name_buf: [512]u8 = undefined;
        var name_builder = std.ArrayList(u8).fromOwnedSlice(self.allocator, composite_name_buf[0..0]);
        defer name_builder.deinit();

        // Build composite index name: label_prop1_prop2_..._composite_idx
        name_builder.writer().print("{s}", .{label}) catch return null;
        for (properties) |prop| {
            name_builder.writer().print("_{s}", .{prop}) catch return null;
        }
        name_builder.writer().print("_composite_idx") catch return null;

        const composite_name = name_builder.items;

        if (self.index_manager.property_indexes.contains(composite_name)) {
            // Calculate composite selectivity (product of individual selectivities)
            var composite_selectivity: f64 = 1.0;
            for (properties) |prop| {
                const individual_selectivity = self.estimateIndexSelectivity(.btree, prop);
                composite_selectivity *= individual_selectivity;
            }

            // Composite indexes are typically B-tree based for range and equality queries
            const index_info = IndexInfo{
                .name = self.allocator.dupe(u8, composite_name) catch return null,
                .label = label,
                .property = if (properties.len > 0) properties[0] else "", // Primary property
                .properties = self.allocator.dupe([]const u8, properties) catch return null,
                .index_type = .btree,
                .selectivity = composite_selectivity,
                .is_composite = true,
            };

            const cost = self.estimateCompositeIndexBaseCost(properties.len) * composite_selectivity;
            
            if (cost < best_cost) {
                best_cost = cost;
                best_index = index_info;
            }
        }

        return best_index;
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

    // Estimate selectivity based on index type and property characteristics
    fn estimateIndexSelectivity(self: *IndexOptimizer, index_type: IndexType, property: []const u8) f64 {
        _ = self;
        
        return switch (index_type) {
            .btree => blk: {
                // B-tree good for range queries and exact matches
                // Selectivity depends on data distribution
                if (std.mem.eql(u8, property, "id")) break :blk 0.001; // Very selective for IDs
                if (std.mem.eql(u8, property, "name")) break :blk 0.1;  // Moderately selective for names
                if (std.mem.eql(u8, property, "age")) break :blk 0.02;  // Good for numeric ranges
                break :blk 0.1; // Default selectivity
            },
            .hash => blk: {
                // Hash indexes excellent for exact equality but no range queries
                // Very fast O(1) lookup but limited functionality
                if (std.mem.eql(u8, property, "id")) break :blk 0.001; // Excellent for unique IDs
                if (std.mem.eql(u8, property, "status")) break :blk 0.2; // Good for enumerated values
                break :blk 0.1; // Default for exact matches
            },
            .spatial => blk: {
                // Spatial indexes for geometric data (points, polygons, etc.)
                // Good selectivity for geographic queries
                if (std.mem.eql(u8, property, "location")) break :blk 0.05;
                if (std.mem.eql(u8, property, "coordinates")) break :blk 0.03;
                if (std.mem.eql(u8, property, "geometry")) break :blk 0.08;
                break :blk 0.5; // Poor selectivity for non-spatial data
            },
            .fulltext => blk: {
                // Full-text indexes for text search
                // Selectivity varies greatly based on text content and query
                if (std.mem.eql(u8, property, "description")) break :blk 0.15;
                if (std.mem.eql(u8, property, "content")) break :blk 0.2;
                if (std.mem.eql(u8, property, "title")) break :blk 0.1;
                break :blk 0.3; // Default for text properties
            },
        };
    }

    // Estimate cost based on index type characteristics
    fn estimateIndexTypeCost(self: *IndexOptimizer, index_type: IndexType, selectivity: f64) f64 {
        _ = self;
        
        const base_cost = switch (index_type) {
            .btree => 10.0,     // Balanced tree traversal cost
            .hash => 5.0,       // O(1) hash lookup cost
            .spatial => 15.0,   // Spatial index traversal cost
            .fulltext => 20.0,  // Text processing and matching cost
        };
        
        // Cost scales with selectivity - more selective indexes are cheaper to process results
        return base_cost * selectivity;
    }

    // Determine if an index type is suitable for a given query pattern
    fn isIndexTypeSuitableForQuery(
        self: *IndexOptimizer, 
        index_type: IndexType, 
        property: []const u8, 
        query_type: QueryPatternType
    ) bool {
        _ = self;
        _ = property;
        
        return switch (index_type) {
            .btree => switch (query_type) {
                .exact_match, .range_query, .prefix_match => true,
                .spatial_query, .fulltext_search => false,
            },
            .hash => switch (query_type) {
                .exact_match => true,
                .range_query, .prefix_match, .spatial_query, .fulltext_search => false,
            },
            .spatial => switch (query_type) {
                .spatial_query => true,
                .exact_match, .range_query, .prefix_match, .fulltext_search => false,
            },
            .fulltext => switch (query_type) {
                .fulltext_search => true,
                .exact_match, .range_query, .prefix_match, .spatial_query => false,
            },
        };
    }

    // Composite index cost estimation
    fn estimateCompositeIndexCost(
        self: *IndexOptimizer,
        index_info: IndexInfo,
        prop_keys: []const []const u8,
        prop_vals: []const PropertyValue,
    ) f64 {
        _ = prop_keys;
        _ = prop_vals;
        
        const base_cost = self.estimateCompositeIndexBaseCost(index_info.properties.len);
        return base_cost * index_info.selectivity;
    }

    fn estimateCompositeIndexRows(
        self: *IndexOptimizer,
        index_info: IndexInfo,
        prop_keys: []const []const u8,
        prop_vals: []const PropertyValue,
    ) u64 {
        _ = self;
        _ = prop_keys;
        _ = prop_vals;
        
        // Composite indexes should be very selective
        const total_rows: f64 = 1000.0; // Assumed total dataset size
        return @intFromFloat(total_rows * index_info.selectivity);
    }

    fn estimateCompositeIndexBaseCost(self: *IndexOptimizer, property_count: usize) f64 {
        _ = self;
        
        // Base cost increases slightly with more properties but is still much better than sequential
        return 8.0 + (@as(f64, @floatFromInt(property_count)) * 2.0);
    }

    // EXPLAIN functionality helpers
    fn createSequentialScanExplain(self: *IndexOptimizer, labels: []const []const u8, cost: f64, rows: u64) ?graph_common.ExplainInfo {
        _ = rows;
        
        const operation = self.allocator.dupe(u8, "Sequential Scan") catch return null;
        
        var details_buf: [256]u8 = undefined;
        const details = std.fmt.bufPrint(&details_buf, "Scanning all nodes with labels: {any}", .{labels}) catch return null;
        const details_owned = self.allocator.dupe(u8, details) catch return null;

        var cost_components = self.allocator.alloc(graph_common.CostComponent, 1) catch return null;
        cost_components[0] = graph_common.CostComponent{
            .component = self.allocator.dupe(u8, "Node Scan") catch return null,
            .cost = cost,
            .description = self.allocator.dupe(u8, "Full table scan of all nodes") catch return null,
        };

        return graph_common.ExplainInfo{
            .operation = operation,
            .details = details_owned,
            .cost_breakdown = cost_components,
            .index_usage = null,
        };
    }

    fn createIndexScanExplain(
        self: *IndexOptimizer, 
        index_info: IndexInfo, 
        cost: f64, 
        rows: u64,
        prop_keys: []const []const u8,
        is_composite: bool
    ) ?graph_common.ExplainInfo {
        _ = rows;
        
        const operation = if (is_composite) 
            self.allocator.dupe(u8, "Composite Index Scan") catch return null
        else 
            self.allocator.dupe(u8, "Index Scan") catch return null;
        
        var details_buf: [512]u8 = undefined;
        const details = if (is_composite)
            std.fmt.bufPrint(&details_buf, "Using composite index on properties: {any}", .{prop_keys}) catch return null
        else
            std.fmt.bufPrint(&details_buf, "Using index on property: {s}", .{index_info.property}) catch return null;
        const details_owned = self.allocator.dupe(u8, details) catch return null;

        // Cost breakdown
        var cost_components = self.allocator.alloc(graph_common.CostComponent, 2) catch return null;
        
        const base_cost = if (is_composite) 
            self.estimateCompositeIndexBaseCost(index_info.properties.len)
        else 
            self.estimateIndexTypeCost(index_info.index_type, 1.0);
            
        cost_components[0] = graph_common.CostComponent{
            .component = self.allocator.dupe(u8, "Index Lookup") catch return null,
            .cost = base_cost,
            .description = self.allocator.dupe(u8, "Cost to traverse index structure") catch return null,
        };
        
        cost_components[1] = graph_common.CostComponent{
            .component = self.allocator.dupe(u8, "Result Processing") catch return null,
            .cost = cost - base_cost,
            .description = self.allocator.dupe(u8, "Cost to process matching rows") catch return null,
        };

        // Index usage info
        var reason_buf: [256]u8 = undefined;
        const reason = if (is_composite)
            std.fmt.bufPrint(&reason_buf, "Chosen for excellent selectivity ({d:.4}) across {d} properties", .{ index_info.selectivity, index_info.properties.len }) catch return null
        else
            std.fmt.bufPrint(&reason_buf, "Chosen for {s} index type with selectivity {d:.4}", .{ @tagName(index_info.index_type), index_info.selectivity }) catch return null;
        
        const index_usage = graph_common.IndexUsageInfo{
            .index_name = index_info.name,
            .index_type = self.allocator.dupe(u8, @tagName(index_info.index_type)) catch return null,
            .properties = if (is_composite) index_info.properties else &[_][]const u8{index_info.property},
            .selectivity = index_info.selectivity,
            .reason = self.allocator.dupe(u8, reason) catch return null,
        };

        return graph_common.ExplainInfo{
            .operation = operation,
            .details = details_owned,
            .cost_breakdown = cost_components,
            .index_usage = index_usage,
        };
    }

    fn createSequentialScanExplainWithAlternatives(
        self: *IndexOptimizer,
        labels: []const []const u8,
        cost: f64,
        rows: u64,
        considered_indexes: []const IndexConsideration,
    ) ?graph_common.ExplainInfo {
        _ = rows;
        const operation = self.allocator.dupe(u8, "Sequential Scan") catch return null;
        
        var details_buf: [512]u8 = undefined;
        const details = if (considered_indexes.len > 0)
            std.fmt.bufPrint(&details_buf, "No suitable index found. Considered {d} indexes but sequential scan was cheaper", .{considered_indexes.len}) catch return null
        else
            std.fmt.bufPrint(&details_buf, "No indexes available for labels: {any}", .{labels}) catch return null;
        const details_owned = self.allocator.dupe(u8, details) catch return null;

        var cost_components = self.allocator.alloc(graph_common.CostComponent, 1) catch return null;
        cost_components[0] = graph_common.CostComponent{
            .component = self.allocator.dupe(u8, "Node Scan") catch return null,
            .cost = cost,
            .description = self.allocator.dupe(u8, "Full table scan - consider creating indexes") catch return null,
        };

        return graph_common.ExplainInfo{
            .operation = operation,
            .details = details_owned,
            .cost_breakdown = cost_components,
            .index_usage = null,
        };
    }
};

// Helper structure for tracking considered indexes during optimization
const IndexConsideration = struct {
    index_info: IndexInfo,
    cost: f64,
    rows: u64,
    chosen: bool,
};

// Format EXPLAIN output for human readability
pub fn formatExplainOutput(allocator: std.mem.Allocator, explain_info: graph_common.ExplainInfo) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    try output.writer().print("Query Plan:\n");
    try output.writer().print("  Operation: {s}\n", .{explain_info.operation});
    try output.writer().print("  Details: {s}\n", .{explain_info.details});
    
    if (explain_info.cost_breakdown.len > 0) {
        try output.writer().print("  Cost Breakdown:\n");
        var total_cost: f64 = 0;
        for (explain_info.cost_breakdown) |component| {
            try output.writer().print("    - {s}: {d:.2} ({s})\n", .{ component.component, component.cost, component.description });
            total_cost += component.cost;
        }
        try output.writer().print("    Total Cost: {d:.2}\n", .{total_cost});
    }
    
    if (explain_info.index_usage) |index_usage| {
        try output.writer().print("  Index Usage:\n");
        try output.writer().print("    Index Name: {s}\n", .{index_usage.index_name});
        try output.writer().print("    Index Type: {s}\n", .{index_usage.index_type});
        try output.writer().print("    Properties: {any}\n", .{index_usage.properties});
        try output.writer().print("    Selectivity: {d:.4}\n", .{index_usage.selectivity});
        try output.writer().print("    Reason: {s}\n", .{index_usage.reason});
    }

    return output.toOwnedSlice();
}

// Query pattern types for index type selection
const QueryPatternType = enum {
    exact_match,    // WHERE property = value
    range_query,    // WHERE property > value AND property < value2
    prefix_match,   // WHERE property STARTS WITH value
    spatial_query,  // Spatial operations (distance, contains, etc.)
    fulltext_search, // Full-text search operations
};
