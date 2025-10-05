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
    stats_manager: ?*@import("index_statistics.zig").IndexStatisticsManager = null,

    pub fn init(allocator: Allocator, idx_mgr: *index_manager) IndexOptimizer {
        return IndexOptimizer{
            .allocator = allocator,
            .index_manager = idx_mgr,
        };
    }

    // Set the statistics manager for enhanced cost estimation
    pub fn setStatisticsManager(self: *IndexOptimizer, stats_mgr: *@import("index_statistics.zig").IndexStatisticsManager) void {
        self.stats_manager = stats_mgr;
    }

    // Initialize vector index statistics when creating a vector index
    pub fn initializeVectorIndexStatistics(
        self: *IndexOptimizer,
        index_name: []const u8,
        label: []const u8,
        property: []const u8,
        dimension: u16,
        index_type: IndexType,
    ) !void {
        if (self.stats_manager) |stats_mgr| {
            // Create statistics for the vector index
            try stats_mgr.createIndexStatistics(index_name, index_type, label, &[_][]const u8{property});

            // Set vector-specific parameters
            if (stats_mgr.getIndexStatistics(index_name)) |stats| {
                stats.setVectorParameters(dimension);
            }
        }
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
            best_plan.explain_info = self.createSequentialScanExplainWithAlternatives(labels, best_plan.estimated_cost, best_plan.estimated_rows, considered_indexes.items);
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
            const node = entry.value_ptr;

            // Check if node matches any of the required labels
            if (labels.len > 0) {
                var has_label = false;
                for (labels) |required_label| {
                    for (node.*.labels) |node_label| {
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
                    const node_prop_val = node.*.properties.get(key) orelse continue;
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
            if (graph.nodes.getPtr(node_id)) |node| {
                // Verify node matches all criteria (labels, property value)
                if (self.nodeMatchesCriteria(node.*, labels, prop_key, prop_val)) {
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
        // Enhanced cost estimation with BM25 integration for fulltext indexes
        switch (index_info.index_type) {
            .fulltext => {
                // Use BM25-enhanced cost estimation for fulltext searches
                const use_bm25 = true; // Enable BM25 scoring by default
                return self.estimateEnhancedFulltextCost(
                    index_info.properties[0], // Primary property for fulltext index
                    prop_val,
                    index_info.name,
                    use_bm25,
                );
            },
            else => {
                // Standard cost estimation for other index types
                return 10.0 * index_info.selectivity;
            },
        }
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
            .VectorF32 => |v| std.fmt.allocPrint(self.allocator, "vector_{d}x{d}", .{ v.dim, v.data.len }),
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
        // First try to get actual statistics if available
        if (self.stats_manager) |stats_mgr| {
            // Try to find index statistics for this property
            var index_name_buf: [256]u8 = undefined;
            const index_name = std.fmt.bufPrint(&index_name_buf, "_{s}_{s}_idx", .{ property, @tagName(index_type) }) catch property;

            if (stats_mgr.getIndexStatistics(index_name)) |stats| {
                // Use actual selectivity from collected statistics
                return stats.getEstimatedSelectivity();
            }
        }

        // Fallback to heuristic-based estimates if no statistics available
        return switch (index_type) {
            .btree => blk: {
                // B-tree good for range queries and exact matches
                // Selectivity depends on data distribution
                if (std.mem.eql(u8, property, "id")) break :blk 0.001; // Very selective for IDs
                if (std.mem.eql(u8, property, "name")) break :blk 0.1; // Moderately selective for names
                if (std.mem.eql(u8, property, "age")) break :blk 0.02; // Good for numeric ranges
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
                // Full-text indexes for text search with BM25 scoring
                // CANARY: REQ=REQ-GQL-FTS-004; FEATURE="FTS IndexOptimizer"; ASPECT=CostEstimation; STATUS=IMPL; TEST=TestCANARY_FTSIndexOptimizer; OWNER=fts; UPDATED=2025-10-04

                // Try to get advanced FTS statistics first
                if (self.stats_manager) |stats_mgr| {
                    var index_name_buf: [256]u8 = undefined;
                    const index_name = std.fmt.bufPrint(&index_name_buf, "_{s}_fulltext_idx", .{property}) catch "";

                    if (stats_mgr.getIndexStatistics(index_name)) |stats| {
                        // Use sophisticated FTS selectivity based on corpus characteristics
                        var selectivity = stats.getEstimatedSelectivity();

                        // Adjust based on FTS-specific factors
                        if (stats.fts_total_documents > 0) {
                            // Factor in vocabulary density
                            const vocab_density = @as(f64, @floatFromInt(stats.fts_vocabulary_size)) / @as(f64, @floatFromInt(stats.fts_total_documents));
                            if (vocab_density > 100.0) {
                                selectivity *= 0.8; // Rich vocabulary = more selective
                            } else if (vocab_density < 20.0) {
                                selectivity *= 1.2; // Sparse vocabulary = less selective
                            }

                            // Factor in document length variance
                            if (stats.fts_avg_document_length > 500.0) {
                                selectivity *= 0.9; // Long documents = more selective matches
                            }
                        }

                        break :blk selectivity;
                    }
                }

                // Fallback to heuristic-based estimates for common text fields
                if (std.mem.eql(u8, property, "description")) break :blk 0.15;
                if (std.mem.eql(u8, property, "content")) break :blk 0.2;
                if (std.mem.eql(u8, property, "title")) break :blk 0.1;
                if (std.mem.eql(u8, property, "summary")) break :blk 0.12;
                if (std.mem.eql(u8, property, "abstract")) break :blk 0.08;
                if (std.mem.eql(u8, property, "body")) break :blk 0.25;
                if (std.mem.eql(u8, property, "comment")) break :blk 0.3;
                break :blk 0.3; // Default for text properties
            },
        };
    }

    // Estimate cost based on index type characteristics
    fn estimateIndexTypeCost(self: *IndexOptimizer, index_type: IndexType, selectivity: f64) f64 {
        const base_cost = switch (index_type) {
            .btree => 10.0, // Balanced tree traversal cost
            .hash => 5.0, // O(1) hash lookup cost
            .spatial => 15.0, // Spatial index traversal cost
            .fulltext => 20.0, // Text processing and matching cost
        };

        // Apply statistics-based cost factors if available
        var cost_factor: f64 = 1.0;
        if (self.stats_manager) |stats_mgr| {
            // Check if we have statistics for any index of this type
            const all_stats = stats_mgr.getAllStatistics();
            defer self.allocator.free(all_stats);

            for (all_stats) |stats| {
                if (stats.index_type == index_type) {
                    // Use the cost factor from statistics
                    cost_factor = stats.getEstimatedCostFactor();

                    // For FTS indexes, apply additional cost factors based on corpus characteristics
                    if (index_type == .fulltext and stats.fts_total_documents > 0) {
                        // Adjust cost based on average document length
                        const doc_length_factor = 1.0 + (stats.fts_avg_document_length - 100.0) / 500.0;
                        cost_factor *= @max(0.5, @min(2.0, doc_length_factor));

                        // Adjust based on vocabulary complexity
                        const vocab_complexity = @as(f64, @floatFromInt(stats.fts_vocabulary_size)) / @as(f64, @floatFromInt(stats.fts_total_documents));
                        if (vocab_complexity > 50.0) {
                            cost_factor *= 1.1; // Complex vocabulary = higher processing cost
                        }

                        // Adjust based on search efficiency (hit ratio)
                        if (stats.fts_search_queries > 10) {
                            if (stats.hit_ratio > 0.7) {
                                cost_factor *= 0.9; // Efficient searches cost less
                            } else if (stats.hit_ratio < 0.3) {
                                cost_factor *= 1.2; // Inefficient searches cost more
                            }
                        }
                    }
                    break;
                }
            }
        }

        // Cost scales with selectivity - more selective indexes are cheaper to process results
        return base_cost * selectivity * cost_factor;
    }

    // BM25-enhanced cost estimation for fulltext search queries
    // Implements BM25 scoring cost estimation using the mathematical model:
    // score = IDF * ((tf * (k1 + 1)) / (tf + k1 * (1 - b + b * (|d| / avgdl))))
    fn estimateBM25FulltextCost(
        self: *IndexOptimizer,
        query_terms: []const []const u8,
        index_name: []const u8,
        corpus_size: u64,
    ) f64 {
        // BM25 parameters (commonly used defaults)
        const k1: f64 = 1.2; // Term frequency saturation parameter
        const b: f64 = 0.75;  // Length normalization parameter
        
        // Base BM25 computational cost (higher than regular fulltext due to scoring)
        var base_cost: f64 = 25.0;

        // Cost scales with query complexity (number of terms)
        const query_complexity_factor = 1.0 + (@as(f64, @floatFromInt(query_terms.len)) - 1.0) * 0.3;
        base_cost *= query_complexity_factor;

        // Cost scales with corpus size (logarithmically for IDF computation)
        if (corpus_size > 0) {
            const corpus_factor = 1.0 + @log(@as(f64, @floatFromInt(corpus_size))) / 10.0;
            base_cost *= corpus_factor;
        }

        // Enhanced BM25 cost estimation using available statistics
        if (self.stats_manager) |stats_mgr| {
            if (stats_mgr.getIndexStatistics(index_name)) |stats| {
                var bm25_cost_factor: f64 = 1.0;
                
                if (stats.fts_total_documents > 0) {
                    // Factor in vocabulary complexity for IDF computation cost
                    const vocab_size = @as(f64, @floatFromInt(stats.fts_vocabulary_size));
                    const doc_count = @as(f64, @floatFromInt(stats.fts_total_documents));
                    const vocab_density = vocab_size / doc_count;
                    
                    // More complex vocabulary requires more IDF computations
                    if (vocab_density > 100.0) {
                        bm25_cost_factor *= 1.2; // Complex vocabulary = higher IDF cost
                    } else if (vocab_density < 20.0) {
                        bm25_cost_factor *= 0.9; // Simple vocabulary = lower IDF cost  
                    }

                    // Factor in document length variance for normalization cost
                    // BM25 normalization: k1 * (1 - b + b * (|d| / avgdl))
                    const avg_doc_len = stats.fts_avg_document_length;
                    if (avg_doc_len > 0) {
                        // Longer documents require more normalization computation
                        const length_norm_cost = 1.0 + (avg_doc_len - 200.0) / 1000.0;
                        bm25_cost_factor *= @max(0.8, @min(1.5, length_norm_cost));
                        
                        // Additional cost for b parameter length normalization
                        const b_factor_cost = 1.0 + (b * 0.2); // b=0.75 adds ~15% cost
                        bm25_cost_factor *= b_factor_cost;
                    }

                    // Factor in term frequency processing (k1 parameter impact)
                    // Higher k1 values require more tf normalization computation  
                    const k1_factor_cost = 1.0 + (k1 - 1.0) * 0.1; // k1=1.2 adds ~2% cost
                    bm25_cost_factor *= k1_factor_cost;

                    base_cost *= bm25_cost_factor;
                }

                // Apply historical BM25 performance data
                if (stats.fts_search_queries > 5) {
                    // BM25 scoring efficiency based on hit ratios
                    const bm25_efficiency = stats.hit_ratio * 0.4 + 0.6; // Between 0.6-1.0
                    base_cost *= bm25_efficiency;
                }
            }
        }

        return base_cost;
    }

    // Enhanced fulltext search with BM25 scoring integration
    fn estimateEnhancedFulltextCost(
        self: *IndexOptimizer,
        property: []const u8,
        search_value: PropertyValue,
        index_name: []const u8,
        use_bm25: bool,
    ) f64 {
        // Extract search terms from query
        var query_terms: []const []const u8 = &[_][]const u8{};
        var corpus_size: u64 = 1000; // Default estimate

        // Parse search terms from PropertyValue
        switch (search_value) {
            .String => |search_text| {
                // For this implementation, treat the entire search as one term
                // In a real implementation, this would be tokenized
                query_terms = &[_][]const u8{search_text};
            },
            else => {
                // Non-string values fallback to basic cost
                return self.estimateIndexTypeCost(.fulltext, 0.3);
            },
        }

        // Get corpus size from statistics if available
        if (self.stats_manager) |stats_mgr| {
            if (stats_mgr.getIndexStatistics(index_name)) |stats| {
                corpus_size = stats.fts_total_documents;
            }
        }

        if (use_bm25) {
            return self.estimateBM25FulltextCost(query_terms, index_name, corpus_size);
        } else {
            // Standard fulltext cost estimation
            const selectivity = self.estimatePropertySelectivity(.fulltext, property);
            return self.estimateIndexTypeCost(.fulltext, selectivity);
        }
    }

    // Determine if an index type is suitable for a given query pattern
    fn isIndexTypeSuitableForQuery(self: *IndexOptimizer, index_type: IndexType, property: []const u8, query_type: QueryPatternType) bool {
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

    fn createIndexScanExplain(self: *IndexOptimizer, index_info: IndexInfo, cost: f64, rows: u64, prop_keys: []const []const u8, is_composite: bool) ?graph_common.ExplainInfo {
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

    // Optimize full-text search queries with BM25 scoring and advanced statistics
    // CANARY: REQ=REQ-GQL-FTS-005; FEATURE="FTS Query Optimization"; ASPECT=QueryPlanning; STATUS=IMPL; TEST=TestCANARY_FTSQueryOptimization; OWNER=fts; UPDATED=2025-10-04
    pub fn optimizeFtsQuery(
        self: *IndexOptimizer,
        labels: []const []const u8,
        text_property: []const u8,
        query_terms: []const []const u8,
        query_type: @import("index_statistics.zig").IndexStatistics.FtsQueryType,
    ) ScanPlan {
        var best_plan = ScanPlan{
            .type = .sequential,
            .estimated_cost = self.estimateSequentialScanCost(labels),
            .estimated_rows = self.estimateSequentialScanRows(labels),
            .explain_info = null,
        };

        // Look for full-text indexes on the specified property
        for (labels) |label| {
            var index_name_buf: [256]u8 = undefined;
            const index_name = std.fmt.bufPrint(&index_name_buf, "{s}_{s}_fulltext_idx", .{ label, text_property }) catch continue;

            if (self.index_manager.property_indexes.contains(index_name)) {
                const index_info = IndexInfo{
                    .name = self.allocator.dupe(u8, index_name) catch continue,
                    .label = label,
                    .property = text_property,
                    .index_type = .fulltext,
                };

                // Calculate FTS-specific cost
                const fts_cost = self.estimateFtsQueryCost(index_info, query_terms, query_type);
                const fts_rows = self.estimateFtsResultRows(index_info, query_terms, query_type);

                if (fts_cost < best_plan.estimated_cost) {
                    best_plan = ScanPlan{
                        .type = .{ .index = index_info },
                        .estimated_cost = fts_cost,
                        .estimated_rows = fts_rows,
                        .explain_info = self.createFtsExplainInfo(index_info, fts_cost, fts_rows, query_terms, query_type),
                    };
                }
            }
        }

        return best_plan;
    }

    // Estimate cost for full-text search query
    fn estimateFtsQueryCost(
        self: *IndexOptimizer,
        index_info: IndexInfo,
        query_terms: []const []const u8,
        query_type: @import("index_statistics.zig").IndexStatistics.FtsQueryType,
    ) f64 {
        // Use statistics-based cost estimation if available
        if (self.stats_manager) |stats_mgr| {
            if (stats_mgr.getIndexStatistics(index_info.name)) |stats| {
                return stats.estimateFtsCost(@intCast(query_terms.len), query_type);
            }
        }

        // Fallback to heuristic-based cost estimation
        const base_cost: f64 = 20.0; // Base full-text search cost
        const terms_factor = @as(f64, @floatFromInt(query_terms.len));

        const query_complexity_factor: f64 = switch (query_type) {
            .simple => 1.0,
            .phrase => 1.5,
            .proximity => 2.0,
        };

        // Estimate based on typical text corpus characteristics
        const estimated_docs: f64 = 1000.0; // Default document count
        const log_docs = @log(estimated_docs);

        return base_cost * terms_factor * query_complexity_factor * log_docs;
    }

    // Estimate result rows for full-text search
    fn estimateFtsResultRows(
        self: *IndexOptimizer,
        index_info: IndexInfo,
        query_terms: []const []const u8,
        query_type: @import("index_statistics.zig").IndexStatistics.FtsQueryType,
    ) u64 {
        _ = query_type;

        // Use statistics if available
        if (self.stats_manager) |stats_mgr| {
            if (stats_mgr.getIndexStatistics(index_info.name)) |stats| {
                // Estimate based on historical hit ratios and document count
                const base_docs = stats.fts_total_documents;
                if (base_docs > 0) {
                    var selectivity = stats.hit_ratio;

                    // Adjust based on query complexity
                    const terms_factor = 1.0 / @as(f64, @floatFromInt(query_terms.len + 1));
                    selectivity *= terms_factor;

                    return @intFromFloat(@max(1.0, @as(f64, @floatFromInt(base_docs)) * selectivity));
                }
            }
        }

        // Fallback heuristic: more terms = fewer results
        const base_estimate: u64 = 100;
        const terms_penalty = query_terms.len * 2;
        return @max(1, base_estimate - terms_penalty);
    }

    // Create explain information for FTS queries
    fn createFtsExplainInfo(
        self: *IndexOptimizer,
        index_info: IndexInfo,
        cost: f64,
        rows: u64,
        query_terms: []const []const u8,
        query_type: @import("index_statistics.zig").IndexStatistics.FtsQueryType,
    ) ?graph_common.ExplainInfo {
        const operation = self.allocator.dupe(u8, "Full-Text Index Scan") catch return null;

        // Create detailed description
        var desc_buf: [512]u8 = undefined;
        const query_type_str = switch (query_type) {
            .simple => "simple",
            .phrase => "phrase",
            .proximity => "proximity",
        };

        const description = std.fmt.bufPrint(&desc_buf, "Full-text search using BM25 scoring on index '{s}' for {s} query with {} terms. " ++
            "Cost: {d:.2}, Estimated rows: {}", .{ index_info.name, query_type_str, query_terms.len, cost, rows }) catch return null;

        const details_owned = self.allocator.dupe(u8, description) catch return null;

        // Create cost breakdown
        var cost_components = std.ArrayList(graph_common.CostComponent).initCapacity(self.allocator, 0) catch return null;

        cost_components.append(self.allocator, .{
            .operation = self.allocator.dupe(u8, "BM25 Scoring") catch return null,
            .cost = cost * 0.6,
            .description = self.allocator.dupe(u8, "Document scoring and ranking") catch return null,
        }) catch {};

        cost_components.append(self.allocator, .{
            .operation = self.allocator.dupe(u8, "Term Processing") catch return null,
            .cost = cost * 0.3,
            .description = self.allocator.dupe(u8, "Query tokenization and normalization") catch return null,
        }) catch {};

        cost_components.append(self.allocator, .{
            .operation = self.allocator.dupe(u8, "Result Assembly") catch return null,
            .cost = cost * 0.1,
            .description = self.allocator.dupe(u8, "Result formatting and highlights") catch return null,
        }) catch {};

        // Create index usage info
        const index_usage = graph_common.IndexUsageInfo{
            .index_name = self.allocator.dupe(u8, index_info.name) catch return null,
            .index_type = "fulltext",
            .properties = &[_][]const u8{index_info.property},
            .scan_type = "FTS BM25",
            .selectivity = 1.0 / @as(f64, @floatFromInt(rows + 1)),
        };

        return graph_common.ExplainInfo{
            .operation = operation,
            .details = details_owned,
            .cost_breakdown = cost_components.toOwnedSlice(self.allocator) catch return null,
            .index_usage = index_usage,
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
    exact_match, // WHERE property = value
    range_query, // WHERE property > value AND property < value2
    prefix_match, // WHERE property STARTS WITH value
    spatial_query, // Spatial operations (distance, contains, etc.)
    fulltext_search, // Full-text search operations
    vector_knn, // K-nearest neighbor vector search
    vector_similarity, // Vector similarity with distance threshold
    vector_range, // Vector distance within range
};

// Advanced vector distance metrics supported by the optimizer
pub const VectorDistanceMetric = enum {
    l2, // Euclidean distance
    cosine, // Cosine similarity (1 - cosine_distance)
    dot, // Dot product
    manhattan, // Manhattan (L1) distance
    hamming, // Hamming distance (for binary vectors)
    jaccard, // Jaccard similarity

    pub fn toString(self: VectorDistanceMetric) []const u8 {
        return switch (self) {
            .l2 => "l2",
            .cosine => "cosine",
            .dot => "dot",
            .manhattan => "manhattan",
            .hamming => "hamming",
            .jaccard => "jaccard",
        };
    }

    pub fn fromString(str: []const u8) ?VectorDistanceMetric {
        if (std.mem.eql(u8, str, "l2")) return .l2;
        if (std.mem.eql(u8, str, "cosine")) return .cosine;
        if (std.mem.eql(u8, str, "dot")) return .dot;
        if (std.mem.eql(u8, str, "manhattan")) return .manhattan;
        if (std.mem.eql(u8, str, "hamming")) return .hamming;
        if (std.mem.eql(u8, str, "jaccard")) return .jaccard;
        return null;
    }
};

// Vector query types for different search patterns
pub const VectorQueryType = enum {
    knn, // K-nearest neighbors
    similarity_threshold, // Find all vectors within similarity threshold
    distance_range, // Find all vectors within distance range
    approximate_knn, // Approximate K-NN with relaxed precision
};

// Vector query options for advanced search patterns
pub const VectorQueryOptions = struct {
    query_type: VectorQueryType = .knn,
    distance_metric: VectorDistanceMetric = .l2,
    k: u32 = 10,
    similarity_threshold: ?f64 = null, // For similarity_threshold queries
    max_distance: ?f64 = null, // For distance_range queries
    min_distance: ?f64 = null, // For distance_range queries
    ef_search: ?u16 = null, // HNSW search parameter for precision/speed tradeoff
    approximate: bool = false, // Enable approximate search for speed
    include_distances: bool = true, // Include distance scores in results
};

// Vector K-NN query optimization methods
pub const VectorKNNOptimizer = struct {
    // Advanced vector query optimization with comprehensive options support
    pub fn optimizeAdvancedVectorQuery(
        self: *IndexOptimizer,
        property: []const u8,
        query_vector: []const f32,
        options: VectorQueryOptions,
        labels: []const []const u8,
    ) ScanPlan {
        // Look for available vector indexes on this property
        const best_vector_index = self.findBestVectorIndexAdvanced(property, query_vector.len, options);

        if (best_vector_index) |index_info| {
            const vector_cost = self.estimateAdvancedVectorCost(index_info, options, query_vector.len);
            const estimated_rows = self.estimateVectorQueryRows(options);

            const vector_info = graph_common.AdvancedVectorKNNInfo{
                .index_name = index_info.name,
                .query_vector = query_vector,
                .property = property,
                .options = options,
            };

            return ScanPlan{
                .type = .{ .advanced_vector_knn = vector_info },
                .estimated_cost = vector_cost,
                .estimated_rows = estimated_rows,
                .explain_info = self.createAdvancedVectorExplain(index_info, vector_cost, estimated_rows, options),
            };
        }

        // Fallback to sequential scan with advanced vector processing
        const sequential_cost = self.estimateSequentialAdvancedVectorScanCost(labels, query_vector.len, options);
        const sequential_rows = self.estimateSequentialScanRows(labels);

        return ScanPlan{
            .type = .sequential,
            .estimated_cost = sequential_cost,
            .estimated_rows = sequential_rows,
            .explain_info = self.createSequentialAdvancedVectorScanExplain(labels, sequential_cost, sequential_rows, options),
        };
    }

    // Optimize K-NN vector similarity search with advanced options
    pub fn optimizeVectorKNNScan(
        self: *IndexOptimizer,
        property: []const u8,
        query_vector: []const f32,
        k: u32,
        metric: []const u8,
        labels: []const []const u8,
    ) ScanPlan {
        // Convert legacy parameters to new VectorQueryOptions format
        const options = VectorQueryOptions{
            .query_type = .knn,
            .distance_metric = VectorDistanceMetric.fromString(metric) orelse .l2,
            .k = k,
            .include_distances = true,
        };

        return self.optimizeAdvancedVectorQuery(property, query_vector, options, labels);
    }

    // Legacy method - calls new advanced optimization
    fn optimizeVectorKNNScanLegacy(
        self: *IndexOptimizer,
        property: []const u8,
        query_vector: []const f32,
        k: u32,
        metric: []const u8,
        labels: []const []const u8,
    ) ScanPlan {
        // Look for available vector indexes on this property
        const best_vector_index = self.findBestVectorIndex(property, query_vector.len, metric);

        if (best_vector_index) |index_info| {
            const knn_cost = self.estimateVectorKNNCost(index_info, k, query_vector.len);
            const knn_rows = @min(k, 1000); // K-NN returns at most k results

            return ScanPlan{
                .type = .{ .vector_knn = graph_common.VectorKNNInfo{
                    .index_name = index_info.name,
                    .query_vector = query_vector,
                    .k = k,
                    .metric = metric,
                    .property = property,
                } },
                .estimated_cost = knn_cost,
                .estimated_rows = knn_rows,
                .explain_info = self.createVectorKNNExplain(index_info, knn_cost, knn_rows, k, metric),
            };
        }

        // Fallback to sequential scan with vector distance computation
        const sequential_cost = self.estimateSequentialVectorScanCost(labels, query_vector.len);
        const sequential_rows = self.estimateSequentialScanRows(labels);

        return ScanPlan{
            .type = .sequential,
            .estimated_cost = sequential_cost,
            .estimated_rows = sequential_rows,
            .explain_info = self.createSequentialVectorScanExplain(labels, sequential_cost, sequential_rows, k),
        };
    }

    // Find the best vector index for advanced queries with comprehensive options
    fn findBestVectorIndexAdvanced(
        self: *IndexOptimizer,
        property: []const u8,
        vector_dim: usize,
        options: VectorQueryOptions,
    ) ?IndexInfo {
        // Query index manager for vector indexes on this property
        const available_indexes = self.index_manager.getIndexesForProperty(property) catch return null;
        defer self.allocator.free(available_indexes);

        for (available_indexes) |index_info| {
            if (index_info.index_type == .vector_hnsw or index_info.index_type == .vector_f32) {
                // Check if dimension matches and the index supports the query type
                if (self.vectorIndexSupportsQuery(index_info, vector_dim, options)) {
                    return index_info;
                }
            }
        }

        return null;
    }

    // Check if a vector index supports the specific query requirements
    fn vectorIndexSupportsQuery(
        self: *IndexOptimizer,
        index_info: IndexInfo,
        vector_dim: usize,
        options: VectorQueryOptions,
    ) bool {
        _ = self;
        _ = index_info;
        _ = vector_dim;

        // All HNSW indexes support different query types
        // In production, this would check index metadata for supported metrics
        return switch (options.query_type) {
            .knn, .approximate_knn => true, // HNSW excels at K-NN
            .similarity_threshold => true, // Can be implemented with large K + filtering
            .distance_range => true, // Can be implemented with range search
        };
    }

    // Estimate cost for advanced vector queries
    fn estimateAdvancedVectorCost(
        self: *IndexOptimizer,
        index_info: IndexInfo,
        options: VectorQueryOptions,
        vector_dim: usize,
    ) f64 {
        // Base cost depends on query type
        const base_cost = switch (options.query_type) {
            .knn => self.estimateVectorKNNCost(index_info, options.k, vector_dim),
            .approximate_knn => self.estimateVectorKNNCost(index_info, options.k, vector_dim) * 0.7, // 30% faster
            .similarity_threshold => {
                // Threshold queries require larger search scope
                const effective_k = if (options.similarity_threshold) |_| options.k * 3 else options.k;
                return self.estimateVectorKNNCost(index_info, effective_k, vector_dim) * 1.2;
            },
            .distance_range => {
                // Range queries are most expensive
                const effective_k = options.k * 5; // Much larger search scope
                return self.estimateVectorKNNCost(index_info, effective_k, vector_dim) * 1.5;
            },
        };

        // Apply distance metric cost adjustment
        const metric_factor = switch (options.distance_metric) {
            .l2 => 1.0, // Baseline
            .cosine => 1.1, // Slightly more expensive due to normalization
            .dot => 0.9, // Simpler computation
            .manhattan => 1.05, // L1 distance
            .hamming => 0.8, // Binary operations
            .jaccard => 1.3, // Set operations
        };

        return base_cost * metric_factor;
    }

    // Estimate result set size for different vector query types
    fn estimateVectorQueryRows(self: *IndexOptimizer, options: VectorQueryOptions) u64 {
        _ = self;

        return switch (options.query_type) {
            .knn, .approximate_knn => options.k, // Exactly k results
            .similarity_threshold => {
                // Variable result size based on data distribution
                // Estimate based on threshold selectivity
                if (options.similarity_threshold) |threshold| {
                    if (threshold > 0.9) return options.k; // Very selective
                    if (threshold > 0.7) return options.k * 2; // Moderately selective
                    return options.k * 5; // Broad threshold
                }
                return options.k * 3; // Default estimate
            },
            .distance_range => {
                // Range queries can return many results
                return options.k * 10; // Conservative estimate
            },
        };
    }

    // Estimate cost for sequential scan with advanced vector processing
    fn estimateSequentialAdvancedVectorScanCost(
        self: *IndexOptimizer,
        labels: []const []const u8,
        vector_dim: usize,
        options: VectorQueryOptions,
    ) f64 {
        const base_cost = self.estimateSequentialVectorScanCost(labels, vector_dim);

        // Advanced query types add processing overhead
        const query_overhead = switch (options.query_type) {
            .knn => 1.0, // Baseline
            .approximate_knn => 0.9, // Slightly less precise
            .similarity_threshold => 1.2, // Threshold comparison overhead
            .distance_range => 1.3, // Range checking overhead
        };

        return base_cost * query_overhead;
    }

    // Find the best vector index for a given property and query characteristics
    fn findBestVectorIndex(
        self: *IndexOptimizer,
        property: []const u8,
        vector_dim: usize,
        metric: []const u8,
    ) ?IndexInfo {
        // Query index manager for vector indexes on this property
        const available_indexes = self.index_manager.getIndexesForProperty(property) catch return null;
        defer self.allocator.free(available_indexes);

        for (available_indexes) |index_info| {
            if (index_info.index_type == .vector_hnsw) {
                // Check if dimension and metric match
                if (self.vectorIndexMatches(index_info, vector_dim, metric)) {
                    return index_info;
                }
            }
        }

        return null;
    }

    // Check if a vector index matches the query requirements
    fn vectorIndexMatches(
        self: *IndexOptimizer,
        index_info: IndexInfo,
        vector_dim: usize,
        metric: []const u8,
    ) bool {
        _ = self;
        _ = index_info;
        _ = vector_dim;
        _ = metric;

        // For now, assume all vector indexes match
        // In a full implementation, we'd check index metadata
        return true;
    }

    // Estimate cost for vector K-NN search using HNSW
    fn estimateVectorKNNCost(
        self: *IndexOptimizer,
        index_info: IndexInfo,
        k: u32,
        vector_dim: usize,
    ) f64 {
        // Try to get actual statistics if available
        if (self.stats_manager) |stats_mgr| {
            if (stats_mgr.getIndexStatistics(index_info.name)) |stats| {
                // Use enhanced vector K-NN cost estimation from statistics
                return stats.estimateVectorKnnCost(k, stats.total_entries);
            }
        }

        // Fallback heuristic: HNSW is very efficient for K-NN
        // Base cost of 5.0 for K-NN search, scaled by k and dimension
        const base_cost = 5.0;
        const k_factor = @as(f64, @floatFromInt(k)) / 10.0; // Normalize to k=10
        const dim_factor = @as(f64, @floatFromInt(vector_dim)) / 128.0; // Normalize to 128D
        return base_cost * k_factor * dim_factor;
    }

    // Estimate cost for sequential scan with vector distance computation
    fn estimateSequentialVectorScanCost(
        self: *IndexOptimizer,
        labels: []const []const u8,
        vector_dim: usize,
    ) f64 {
        const base_sequential_cost = self.estimateSequentialScanCost(labels);
        // Vector distance computation adds significant overhead
        const vector_computation_overhead = @as(f64, @floatFromInt(vector_dim)) * 0.1;
        return base_sequential_cost * (1.0 + vector_computation_overhead);
    }

    // Create EXPLAIN output for vector K-NN scan
    fn createVectorKNNExplain(
        self: *IndexOptimizer,
        index_info: IndexInfo,
        cost: f64,
        rows: u64,
        k: u32,
        metric: []const u8,
    ) ?graph_common.ExplainInfo {
        const operation = self.allocator.dupe(u8, "Vector K-NN Search") catch return null;

        var details_buf: [512]u8 = undefined;
        const details = std.fmt.bufPrint(&details_buf, "HNSW index search for {d} nearest neighbors using {s} distance metric", .{ k, metric }) catch return null;
        const details_owned = self.allocator.dupe(u8, details) catch return null;

        var cost_components = self.allocator.alloc(graph_common.CostComponent, 2) catch return null;
        cost_components[0] = graph_common.CostComponent{
            .component = self.allocator.dupe(u8, "HNSW Traversal") catch return null,
            .cost = cost * 0.8,
            .description = self.allocator.dupe(u8, "Hierarchical graph traversal") catch return null,
        };
        cost_components[1] = graph_common.CostComponent{
            .component = self.allocator.dupe(u8, "Distance Computation") catch return null,
            .cost = cost * 0.2,
            .description = self.allocator.dupe(u8, "Vector distance calculations") catch return null,
        };

        const index_usage = self.allocator.create(graph_common.IndexUsageInfo) catch return null;
        index_usage.* = graph_common.IndexUsageInfo{
            .index_name = self.allocator.dupe(u8, index_info.name) catch return null,
            .index_type = self.allocator.dupe(u8, "HNSW Vector") catch return null,
            .properties = if (index_info.properties.len > 0)
                self.allocator.dupe([]const u8, index_info.properties) catch return null
            else
                &[_][]const u8{},
            .selectivity = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(rows + k)),
            .reason = self.allocator.dupe(u8, "Efficient K-NN search with HNSW") catch return null,
        };

        return graph_common.ExplainInfo{
            .operation = operation,
            .details = details_owned,
            .cost_breakdown = cost_components,
            .index_usage = index_usage,
        };
    }

    // Create EXPLAIN output for sequential vector scan
    fn createSequentialVectorScanExplain(
        self: *IndexOptimizer,
        labels: []const []const u8,
        cost: f64,
        rows: u64,
        k: u32,
    ) ?graph_common.ExplainInfo {
        _ = rows; // Suppress unused parameter warning
        const operation = self.allocator.dupe(u8, "Sequential Vector Scan") catch return null;

        var details_buf: [512]u8 = undefined;
        const details = std.fmt.bufPrint(&details_buf, "Scanning all nodes with labels {any} and computing vector distances for K-NN (k={d})", .{ labels, k }) catch return null;
        const details_owned = self.allocator.dupe(u8, details) catch return null;

        var cost_components = self.allocator.alloc(graph_common.CostComponent, 2) catch return null;
        cost_components[0] = graph_common.CostComponent{
            .component = self.allocator.dupe(u8, "Full Table Scan") catch return null,
            .cost = cost * 0.6,
            .description = self.allocator.dupe(u8, "Scanning all nodes") catch return null,
        };
        cost_components[1] = graph_common.CostComponent{
            .component = self.allocator.dupe(u8, "Vector Distance") catch return null,
            .cost = cost * 0.4,
            .description = self.allocator.dupe(u8, "Computing distances for each vector") catch return null,
        };

        return graph_common.ExplainInfo{
            .operation = operation,
            .details = details_owned,
            .cost_breakdown = cost_components,
            .index_usage = null,
        };
    }

    // Execute vector K-NN scan using HNSW index
    pub fn executeVectorKNNScan(
        self: *IndexOptimizer,
        graph: *const GraphStorage,
        knn_info: graph_common.VectorKNNInfo,
        labels: []const []const u8,
        var_name: ?[]const u8,
    ) ![]Binding {
        var results = std.ArrayList(Binding).initCapacity(self.allocator, 0) catch unreachable;
        defer results.deinit(self.allocator);

        // Get the vector index from index manager
        const vector_index = self.index_manager.getVectorIndex(knn_info.index_name) catch {
            // Fallback to sequential scan
            return self.executeSequentialVectorScan(graph, knn_info, labels, var_name);
        };

        // Prepare query vector for the appropriate type
        const query_result = vector_index.searchVectorF32(.{
            .data = knn_info.query_vector,
            .dim = @intCast(knn_info.query_vector.len),
        }, knn_info.k) catch {
            // Fallback to sequential scan on error
            return self.executeSequentialVectorScan(graph, knn_info, labels, var_name);
        };
        defer query_result.deinit();

        // Record vector K-NN query statistics
        if (self.stats_manager) |stats_mgr| {
            // Calculate average distance from results
            var total_distance: f64 = 0;
            for (query_result.results.items) |match| {
                total_distance += match.score;
            }
            const avg_distance = if (query_result.results.items.len > 0)
                total_distance / @as(f64, @floatFromInt(query_result.results.items.len))
            else
                0.0;

            // Record the K-NN query for statistics
            stats_mgr.recordIndexAccess(knn_info.index_name, query_result.results.items.len, 1);
            if (stats_mgr.getIndexStatistics(knn_info.index_name)) |stats| {
                stats.recordVectorKnnQuery(knn_info.k, avg_distance);
            }
        }

        // Convert vector search results to graph bindings
        for (query_result.results.items) |match| {
            if (graph.nodes.getPtr(match.id)) |node| {
                // Verify node matches label criteria
                if (self.nodeMatchesLabels(node.*, labels)) {
                    var binding = Binding.init(self.allocator);
                    binding.name = var_name orelse "n";
                    binding.value = .{ .Node = node };
                    // Add the node to vars map
                    try binding.vars.put(var_name orelse "n", .{ .Node = node });
                    // Add similarity score as a special property
                    const score_decimal = PropertyValue{ .Decimal = .{ .coeff = @intFromFloat(match.score * 1000), .scale = 3 } };
                    try binding.vars.put("_similarity_score", .{ .Value = score_decimal });

                    try results.append(self.allocator, binding);
                }
            }
        }

        return results.toOwnedSlice();
    }

    // Fallback sequential vector scan implementation
    fn executeSequentialVectorScan(
        self: *IndexOptimizer,
        graph: *const GraphStorage,
        knn_info: graph_common.VectorKNNInfo,
        labels: []const []const u8,
        var_name: ?[]const u8,
    ) ![]Binding {
        // This is a simplified implementation that would compute distances
        // for all nodes and select the top-k results
        var candidates = std.ArrayList(struct { node: *graph_common.Node, distance: f64 }).initCapacity(self.allocator, 0) catch unreachable;
        defer candidates.deinit(self.allocator);

        // Scan all nodes
        var node_iter = graph.getAllNodes();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr;

            // Check label matching
            if (!self.nodeMatchesLabels(node.*, labels)) continue;

            // Extract vector property
            if (node.*.properties.get(knn_info.property)) |prop_value| {
                if (prop_value == .VectorF32) {
                    const node_vector = prop_value.VectorF32;
                    if (node_vector.data.len == knn_info.query_vector.len) {
                        // Compute distance (simplified L2 for now)
                        var distance: f64 = 0;
                        for (knn_info.query_vector, node_vector.data) |qv, nv| {
                            const diff = qv - nv;
                            distance += diff * diff;
                        }
                        distance = @sqrt(distance);

                        try candidates.append(self.allocator, .{ .node = node, .distance = distance });
                    }
                }
            }
        }

        // Sort by distance and take top-k
        std.sort.insertion(@TypeOf(candidates.items[0]), candidates.items, {}, struct {
            fn lessThan(_: void, a: @TypeOf(candidates.items[0]), b: @TypeOf(candidates.items[0])) bool {
                return a.distance < b.distance;
            }
        }.lessThan);

        // Convert to bindings
        var results = std.ArrayList(Binding).initCapacity(self.allocator, 0) catch unreachable;
        defer results.deinit(self.allocator);

        const k = @min(knn_info.k, candidates.items.len);
        for (candidates.items[0..k]) |candidate| {
            var binding = Binding.init(self.allocator);
            binding.name = var_name orelse "n";
            binding.value = .{ .Node = candidate.node };
            try binding.vars.put(var_name orelse "n", .{ .Node = candidate.node });
            const distance_decimal = PropertyValue{ .Decimal = .{ .coeff = @intFromFloat(candidate.distance * 1000), .scale = 3 } };
            try binding.vars.put("_similarity_score", .{ .Value = distance_decimal });

            try results.append(self.allocator, binding);
        }

        return results.toOwnedSlice();
    }

    // Helper method to check if node matches labels
    fn nodeMatchesLabels(self: *IndexOptimizer, node: graph_common.Node, labels: []const []const u8) bool {
        _ = self;

        if (labels.len == 0) return true;

        for (labels) |label| {
            var has_label = false;
            for (node.labels.items) |node_label| {
                if (std.mem.eql(u8, node_label, label)) {
                    has_label = true;
                    break;
                }
            }
            if (!has_label) return false;
        }

        return true;
    }
};

// Full-Text Search optimization methods
pub const FullTextOptimizer = struct {
    // Optimize full-text search with BM25 scoring
    pub fn optimizeFullTextSearch(
        self: *IndexOptimizer,
        property: []const u8,
        query_terms: []const []const u8,
        labels: []const []const u8,
        options: FullTextSearchOptions,
    ) ScanPlan {
        // Look for available full-text indexes on this property
        const best_ft_index = self.findBestFullTextIndex(property, query_terms);

        if (best_ft_index) |index_info| {
            const index_cost = self.estimateFullTextIndexCost(
                index_info,
                query_terms,
                options.max_results,
            );

            const sequential_cost = self.estimateSequentialFullTextScanCost(labels, query_terms);

            if (index_cost < sequential_cost) {
                const ft_info = graph_common.FullTextInfo{
                    .index_name = index_info.name,
                    .query_terms = query_terms,
                    .property = property,
                    .analyzer = options.analyzer,
                    .max_results = options.max_results,
                };

                return ScanPlan{
                    .type = .{ .fulltext_search = ft_info },
                    .estimated_cost = index_cost,
                    .estimated_rows = @min(options.max_results, self.estimateRowsFromIndex(index_info, query_terms.len)),
                    .explain_info = self.createFullTextIndexExplain(
                        index_info,
                        index_cost,
                        @min(options.max_results, self.estimateRowsFromIndex(index_info, query_terms.len)),
                        query_terms,
                        options.analyzer,
                    ),
                };
            }
        }

        // Fallback to sequential scan with full-text processing
        const sequential_cost = self.estimateSequentialFullTextScanCost(labels, query_terms);
        const estimated_rows = @min(options.max_results, self.estimateRowsFromLabels(labels));

        return ScanPlan{
            .type = .sequential,
            .estimated_cost = sequential_cost,
            .estimated_rows = estimated_rows,
            .explain_info = self.createSequentialFullTextScanExplain(
                labels,
                sequential_cost,
                estimated_rows,
                query_terms,
            ),
        };
    }

    // Find the best full-text index for the given property and query terms
    fn findBestFullTextIndex(
        self: *IndexOptimizer,
        property: []const u8,
        query_terms: []const []const u8,
    ) ?IndexInfo {
        var best_index: ?IndexInfo = null;
        var best_score: f64 = 0;

        for (self.available_indexes.items) |index| {
            if (index.index_type != .fulltext) continue;
            if (!std.mem.eql(u8, index.property, property)) continue;

            // Score based on term coverage and selectivity
            const term_coverage = self.estimateTermCoverage(index, query_terms);
            const score = index.selectivity * term_coverage;

            if (score > best_score) {
                best_score = score;
                best_index = index;
            }
        }

        return best_index;
    }

    // Estimate how well the index covers the query terms
    fn estimateTermCoverage(
        self: *IndexOptimizer,
        index: IndexInfo,
        query_terms: []const []const u8,
    ) f64 {
        _ = self;
        _ = index;

        // For now, assume good coverage for all terms
        // In production, this would check the inverted index
        const covered_terms = query_terms.len;
        return @as(f64, @floatFromInt(covered_terms)) / @as(f64, @floatFromInt(query_terms.len));
    }

    // Estimate cost for full-text index search
    fn estimateFullTextIndexCost(
        self: *IndexOptimizer,
        index_info: IndexInfo,
        query_terms: []const []const u8,
        max_results: u32,
    ) f64 {
        // Try to get actual statistics if available
        if (self.stats_manager) |stats_mgr| {
            if (stats_mgr.getIndexStatistics(index_info.name)) |stats| {
                // BM25 cost model: logarithmic in collection size, linear in query terms
                const log_size = @log(@as(f64, @floatFromInt(stats.total_entries + 1)));
                const term_cost = @as(f64, @floatFromInt(query_terms.len)) * 2.0; // Cost per term lookup
                const ranking_cost = @as(f64, @floatFromInt(max_results)) * 0.1; // Cost to rank results
                return log_size + term_cost + ranking_cost;
            }
        }

        // Fallback heuristic: Full-text search is efficient with proper indexing
        const base_cost = 15.0; // Base cost for full-text operations
        const term_factor = @as(f64, @floatFromInt(query_terms.len)) * 2.0;
        const result_factor = @as(f64, @floatFromInt(max_results)) * 0.1;
        return base_cost + term_factor + result_factor;
    }

    // Estimate cost for sequential scan with full-text processing
    fn estimateSequentialFullTextScanCost(
        self: *IndexOptimizer,
        labels: []const []const u8,
        query_terms: []const []const u8,
    ) f64 {
        const base_sequential_cost = self.estimateSequentialScanCost(labels);
        // Full-text processing adds significant overhead for tokenization and scoring
        const text_processing_overhead = @as(f64, @floatFromInt(query_terms.len)) * 5.0;
        return base_sequential_cost + text_processing_overhead;
    }

    // Create EXPLAIN output for full-text index scan
    fn createFullTextIndexExplain(
        self: *IndexOptimizer,
        index_info: IndexInfo,
        cost: f64,
        rows: u64,
        query_terms: []const []const u8,
        analyzer: []const u8,
    ) ?graph_common.ExplainInfo {
        _ = rows; // Suppress unused parameter warning
        const operation = self.allocator.dupe(u8, "Full-Text Index Search") catch return null;

        var details_buf: [512]u8 = undefined;
        const details = std.fmt.bufPrint(&details_buf, "BM25 scoring on {d} terms using {s} analyzer with inverted index", .{ query_terms.len, analyzer }) catch return null;
        const details_owned = self.allocator.dupe(u8, details) catch return null;

        var cost_components = self.allocator.alloc(graph_common.CostComponent, 3) catch return null;
        cost_components[0] = graph_common.CostComponent{
            .component = self.allocator.dupe(u8, "Term Lookup") catch return null,
            .cost = cost * 0.5,
            .description = self.allocator.dupe(u8, "Inverted index term retrieval") catch return null,
        };
        cost_components[1] = graph_common.CostComponent{
            .component = self.allocator.dupe(u8, "BM25 Scoring") catch return null,
            .cost = cost * 0.3,
            .description = self.allocator.dupe(u8, "Relevance score computation") catch return null,
        };
        cost_components[2] = graph_common.CostComponent{
            .component = self.allocator.dupe(u8, "Result Ranking") catch return null,
            .cost = cost * 0.2,
            .description = self.allocator.dupe(u8, "Sort by relevance score") catch return null,
        };

        // Index usage info
        var reason_buf: [256]u8 = undefined;
        const reason = std.fmt.bufPrint(&reason_buf, "Chosen for full-text search with {d} query terms and selectivity {d:.4}", .{ query_terms.len, index_info.selectivity }) catch return null;

        const index_usage = graph_common.IndexUsageInfo{
            .index_name = index_info.name,
            .index_type = self.allocator.dupe(u8, @tagName(index_info.index_type)) catch return null,
            .properties = &[_][]const u8{index_info.property},
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

    // Create EXPLAIN output for sequential full-text scan
    fn createSequentialFullTextScanExplain(
        self: *IndexOptimizer,
        labels: []const []const u8,
        cost: f64,
        rows: u64,
        query_terms: []const []const u8,
    ) ?graph_common.ExplainInfo {
        _ = rows; // Suppress unused parameter warning
        const operation = self.allocator.dupe(u8, "Sequential Full-Text Scan") catch return null;

        var details_buf: [512]u8 = undefined;
        const details = std.fmt.bufPrint(&details_buf, "Scanning all nodes with labels {any} and performing full-text matching on {d} terms", .{ labels, query_terms.len }) catch return null;
        const details_owned = self.allocator.dupe(u8, details) catch return null;

        var cost_components = self.allocator.alloc(graph_common.CostComponent, 3) catch return null;
        cost_components[0] = graph_common.CostComponent{
            .component = self.allocator.dupe(u8, "Full Table Scan") catch return null,
            .cost = cost * 0.4,
            .description = self.allocator.dupe(u8, "Scanning all nodes") catch return null,
        };
        cost_components[1] = graph_common.CostComponent{
            .component = self.allocator.dupe(u8, "Text Processing") catch return null,
            .cost = cost * 0.4,
            .description = self.allocator.dupe(u8, "Tokenization and term matching") catch return null,
        };
        cost_components[2] = graph_common.CostComponent{
            .component = self.allocator.dupe(u8, "BM25 Scoring") catch return null,
            .cost = cost * 0.2,
            .description = self.allocator.dupe(u8, "Relevance score computation") catch return null,
        };

        return graph_common.ExplainInfo{
            .operation = operation,
            .details = details_owned,
            .cost_breakdown = cost_components,
            .index_usage = null,
        };
    }

    pub const FullTextSearchOptions = struct {
        max_results: u32 = 10,
        analyzer: []const u8 = "standard",
        use_synonyms: bool = false,
        fuzzy_distance: ?u32 = null,
        highlight: bool = true,
    };

    // Distributed Query Planning Cost Estimation Integration
    // CANARY: REQ=REQ-DISTRIBUTED-INDEX-OPTIMIZER-001; FEATURE="Distributed IndexOptimizer"; ASPECT=FederationAwareCostEstimation; STATUS=IMPL; TEST=TestCANARY_REQ_DISTRIBUTED_INDEX_OPTIMIZER_001; OWNER=distributed; UPDATED=2025-10-05

    /// Distributed query planning cost estimation for federation-aware optimization
    pub fn estimateDistributedQueryCost(
        self: *IndexOptimizer,
        labels: []const []const u8,
        prop_key: ?[]const u8,
        prop_val: ?PropertyValue,
        shard_count: u32,
        is_federated: bool,
    ) DistributedCostEstimate {
        // Get local optimization cost as baseline
        const local_plan = self.optimizeNodeScan(labels, prop_key, prop_val);
        
        if (!is_federated or shard_count <= 1) {
            // Non-distributed scenario
            return DistributedCostEstimate{
                .total_cost = local_plan.estimated_cost,
                .local_cost = local_plan.estimated_cost,
                .coordination_cost = 0.0,
                .network_cost = 0.0,
                .parallelism_factor = 1.0,
                .shard_distribution = &[_]ShardCostBreakdown{},
                .optimization_strategy = .single_shard,
            };
        }

        // Distributed scenario cost estimation
        const network_latency = 5.0; // 5ms baseline latency
        const bandwidth_factor = 1000.0; // 1Gbps bandwidth
        const coordination_overhead = 25.0; // Coordinator overhead
        
        // Calculate per-shard cost with load distribution
        const load_distribution_factor = 1.0 / @as(f64, @floatFromInt(shard_count));
        const per_shard_cost = local_plan.estimated_cost * load_distribution_factor;
        
        // Network cost estimation based on data transfer
        const estimated_transfer_size = @as(f64, @floatFromInt(local_plan.estimated_rows)) * 0.1; // 0.1KB per row estimate
        const network_cost = (estimated_transfer_size / bandwidth_factor) * 1000.0 + network_latency;
        
        // Parallelism benefit calculation
        const parallelism_factor = @min(8.0, @as(f64, @floatFromInt(shard_count))) / @as(f64, @floatFromInt(shard_count));
        
        // Total distributed cost with coordination
        const total_distributed_cost = (per_shard_cost * parallelism_factor) + coordination_overhead + network_cost;
        
        // Determine optimization strategy based on cost comparison
        const optimization_strategy = blk: {
            if (total_distributed_cost < local_plan.estimated_cost * 0.7) {
                break :blk DistributedOptimizationStrategy.full_distribution;
            } else if (shard_count >= 4 and local_plan.estimated_rows > 10000) {
                break :blk DistributedOptimizationStrategy.selective_distribution;
            } else {
                break :blk DistributedOptimizationStrategy.coordinator_only;
            }
        };

        return DistributedCostEstimate{
            .total_cost = total_distributed_cost,
            .local_cost = per_shard_cost,
            .coordination_cost = coordination_overhead,
            .network_cost = network_cost,
            .parallelism_factor = parallelism_factor,
            .shard_distribution = &[_]ShardCostBreakdown{}, // TODO: Implement detailed per-shard breakdown
            .optimization_strategy = optimization_strategy,
        };
    }

    /// Estimate cost for cross-shard index operations
    pub fn estimateCrossShardIndexCost(
        self: *IndexOptimizer,
        operation_type: CrossShardOperation,
        index_types: []const IndexType,
        shard_count: u32,
        data_locality: f64, // 0.0 = fully distributed, 1.0 = co-located
    ) f64 {
        var base_cost: f64 = 0;
        
        // Calculate base cost for each index operation
        for (index_types) |index_type| {
            base_cost += self.estimateIndexTypeCost(index_type, 0.5); // Average selectivity
        }
        
        // Apply operation-specific multipliers
        const operation_multiplier = switch (operation_type) {
            .distributed_join => 2.5, // High coordination cost
            .distributed_aggregation => 2.0, // Medium coordination cost
            .distributed_union => 1.5, // Lower coordination cost
            .cross_shard_lookup => 1.8, // Network lookup cost
        };
        
        // Apply locality factor - better locality = lower cost
        const locality_multiplier = 1.0 + (1.0 - data_locality) * 0.5;
        
        // Apply shard count scaling - logarithmic scaling for coordination complexity
        const shard_scaling = 1.0 + @log(@as(f64, @floatFromInt(shard_count))) / 10.0;
        
        return base_cost * operation_multiplier * locality_multiplier * shard_scaling;
    }

    /// Get federation-aware index recommendations
    pub fn getFederationIndexRecommendations(
        self: *IndexOptimizer,
        query_patterns: []const QueryPattern,
        shard_topology: ShardTopology,
    ) []IndexRecommendation {
        _ = self;
        _ = query_patterns;
        _ = shard_topology;
        
        // TODO: Implement detailed federation-aware index recommendations
        // This would analyze query patterns across shards and recommend optimal index placement
        return &[_]IndexRecommendation{};
    }
};

// Supporting types for distributed query planning cost estimation

pub const DistributedCostEstimate = struct {
    total_cost: f64,
    local_cost: f64,
    coordination_cost: f64,
    network_cost: f64,
    parallelism_factor: f64,
    shard_distribution: []const ShardCostBreakdown,
    optimization_strategy: DistributedOptimizationStrategy,
};

pub const ShardCostBreakdown = struct {
    shard_id: u32,
    local_cost: f64,
    data_transfer_cost: f64,
    estimated_rows: u64,
    index_utilization: f64,
};

pub const DistributedOptimizationStrategy = enum {
    single_shard,           // Execute on single shard
    coordinator_only,       // Coordinator handles most work
    selective_distribution, // Distribute only beneficial parts
    full_distribution,      // Full distributed execution
};

pub const CrossShardOperation = enum {
    distributed_join,
    distributed_aggregation,
    distributed_union,
    cross_shard_lookup,
};

pub const QueryPattern = struct {
    labels: []const []const u8,
    properties: []const []const u8,
    frequency: f64,
    selectivity: f64,
};

pub const ShardTopology = struct {
    shard_count: u32,
    replication_factor: u32,
    data_distribution: DataDistributionStrategy,
    network_latency_matrix: []const []const f64,
};

pub const DataDistributionStrategy = enum {
    hash_based,
    range_based,
    geographic,
    custom,
};

pub const IndexRecommendation = struct {
    index_type: IndexType,
    properties: []const []const u8,
    target_shards: []const u32,
    priority: f64,
    estimated_benefit: f64,
    reason: []const u8,
};
