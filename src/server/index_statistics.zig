const std = @import("std");
const Allocator = std.mem.Allocator;
const geode = @import("geode");
const graph_common = geode.graph_common;

// Index statistics collection for better cost estimation
// CANARY: REQ=REQ-GQL-016; FEATURE="IndexStatistics"; ASPECT=CostEstimation; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_016_IndexStatistics; OWNER=engine; UPDATED=2025-10-03

pub const IndexStatistics = struct {
    name: []const u8,
    index_type: graph_common.IndexType,
    label: []const u8,
    properties: []const []const u8,
    
    // Statistical data
    total_entries: u64 = 0,
    unique_values: u64 = 0,
    null_count: u64 = 0,
    avg_key_length: f64 = 0.0,
    selectivity: f64 = 0.1, // Default selectivity
    
    // Usage statistics
    access_count: u64 = 0,
    last_accessed: i64 = 0,
    hit_ratio: f64 = 0.0,
    
    // Histogram for value distribution (simplified)
    value_distribution: std.HashMap([]const u8, u64, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    
    pub fn init(allocator: Allocator, name: []const u8, index_type: graph_common.IndexType, label: []const u8, properties: []const []const u8) IndexStatistics {
        return IndexStatistics{
            .name = name,
            .index_type = index_type,
            .label = label,
            .properties = properties,
            .value_distribution = std.HashMap([]const u8, u64, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }
    
    pub fn deinit(self: *IndexStatistics) void {
        self.value_distribution.deinit();
    }
    
    // Update statistics when a new entry is added to the index
    pub fn recordIndexEntry(self: *IndexStatistics, key: []const u8, is_new_unique: bool) void {
        self.total_entries += 1;
        
        if (is_new_unique) {
            self.unique_values += 1;
        }
        
        // Update average key length
        const new_length = @as(f64, @floatFromInt(key.len));
        self.avg_key_length = (self.avg_key_length * @as(f64, @floatFromInt(self.total_entries - 1)) + new_length) / @as(f64, @floatFromInt(self.total_entries));
        
        // Update selectivity estimate
        if (self.total_entries > 0) {
            self.selectivity = @as(f64, @floatFromInt(self.unique_values)) / @as(f64, @floatFromInt(self.total_entries));
        }
        
        // Update value distribution histogram
        if (self.value_distribution.getPtr(key)) |count_ptr| {
            count_ptr.* += 1;
        } else {
            // For memory efficiency, only track first 1000 unique values
            if (self.value_distribution.count() < 1000) {
                self.value_distribution.put(key, 1) catch {};
            }
        }
    }
    
    // Record index access for usage statistics
    pub fn recordAccess(self: *IndexStatistics, found_entries: u64, total_searched: u64) void {
        self.access_count += 1;
        self.last_accessed = std.time.timestamp();
        
        // Update hit ratio
        if (total_searched > 0) {
            const current_hit_ratio = @as(f64, @floatFromInt(found_entries)) / @as(f64, @floatFromInt(total_searched));
            self.hit_ratio = (self.hit_ratio * @as(f64, @floatFromInt(self.access_count - 1)) + current_hit_ratio) / @as(f64, @floatFromInt(self.access_count));
        }
    }
    
    // Get estimated selectivity based on collected statistics
    pub fn getEstimatedSelectivity(self: *const IndexStatistics) f64 {
        return self.selectivity;
    }
    
    // Get estimated cost factor based on index characteristics
    pub fn getEstimatedCostFactor(self: *const IndexStatistics) f64 {
        var cost_factor: f64 = 1.0;
        
        // Adjust based on index type
        cost_factor *= switch (self.index_type) {
            .hash => 0.8,     // Hash indexes are generally faster
            .btree => 1.0,    // Baseline
            .spatial => 1.3,  // Spatial indexes have overhead
            .fulltext => 1.5, // Full-text searches are more expensive
        };
        
        // Adjust based on average key length (longer keys = more expensive comparisons)
        if (self.avg_key_length > 10.0) {
            cost_factor *= 1.0 + (self.avg_key_length - 10.0) / 50.0;
        }
        
        // Adjust based on hit ratio (lower hit ratio = less efficient)
        if (self.hit_ratio < 0.5) {
            cost_factor *= 1.2;
        }
        
        return cost_factor;
    }
};

pub const IndexStatisticsManager = struct {
    allocator: Allocator,
    statistics: std.HashMap([]const u8, IndexStatistics, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    
    pub fn init(allocator: Allocator) IndexStatisticsManager {
        return IndexStatisticsManager{
            .allocator = allocator,
            .statistics = std.HashMap([]const u8, IndexStatistics, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }
    
    pub fn deinit(self: *IndexStatisticsManager) void {
        var iter = self.statistics.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.statistics.deinit();
    }
    
    // Create statistics tracking for a new index
    pub fn createIndexStatistics(
        self: *IndexStatisticsManager, 
        name: []const u8, 
        index_type: graph_common.IndexType, 
        label: []const u8, 
        properties: []const []const u8
    ) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        const owned_label = try self.allocator.dupe(u8, label);
        const owned_properties = try self.allocator.alloc([]const u8, properties.len);
        for (properties, 0..) |prop, i| {
            owned_properties[i] = try self.allocator.dupe(u8, prop);
        }
        
        const stats = IndexStatistics.init(self.allocator, owned_name, index_type, owned_label, owned_properties);
        try self.statistics.put(owned_name, stats);
    }
    
    // Remove statistics for a dropped index
    pub fn removeIndexStatistics(self: *IndexStatisticsManager, name: []const u8) void {
        if (self.statistics.getPtr(name)) |stats| {
            stats.deinit();
            _ = self.statistics.remove(name);
        }
    }
    
    // Record that an entry was added to an index
    pub fn recordIndexEntry(self: *IndexStatisticsManager, index_name: []const u8, key: []const u8, is_new_unique: bool) void {
        if (self.statistics.getPtr(index_name)) |stats| {
            stats.recordIndexEntry(key, is_new_unique);
        }
    }
    
    // Record that an index was accessed
    pub fn recordIndexAccess(self: *IndexStatisticsManager, index_name: []const u8, found_entries: u64, total_searched: u64) void {
        if (self.statistics.getPtr(index_name)) |stats| {
            stats.recordAccess(found_entries, total_searched);
        }
    }
    
    // Get statistics for an index
    pub fn getIndexStatistics(self: *const IndexStatisticsManager, index_name: []const u8) ?*const IndexStatistics {
        return self.statistics.getPtr(index_name);
    }
    
    // Get all index statistics
    pub fn getAllStatistics(self: *const IndexStatisticsManager) []const IndexStatistics {
        var results = std.ArrayList(IndexStatistics).init(self.allocator);
        defer results.deinit();
        
        var iter = self.statistics.valueIterator();
        while (iter.next()) |stats| {
            results.append(stats.*) catch continue;
        }
        
        return results.toOwnedSlice() catch &.{};
    }
    
    // Analyze index usage and provide recommendations
    pub fn analyzeIndexUsage(self: *const IndexStatisticsManager, allocator: Allocator) ![]u8 {
        var analysis = std.ArrayList(u8).init(allocator);
        defer analysis.deinit();
        
        try analysis.writer().print("Index Usage Analysis:\n");
        try analysis.writer().print("===================\n\n");
        
        var total_indexes: u32 = 0;
        var unused_indexes: u32 = 0;
        var inefficient_indexes: u32 = 0;
        
        var iter = self.statistics.valueIterator();
        while (iter.next()) |stats| {
            total_indexes += 1;
            
            try analysis.writer().print("Index: {s}\n", .{stats.name});
            try analysis.writer().print("  Type: {s}\n", .{@tagName(stats.index_type)});
            try analysis.writer().print("  Label: {s}\n", .{stats.label});
            try analysis.writer().print("  Properties: {any}\n", .{stats.properties});
            try analysis.writer().print("  Total Entries: {d}\n", .{stats.total_entries});
            try analysis.writer().print("  Unique Values: {d}\n", .{stats.unique_values});
            try analysis.writer().print("  Selectivity: {d:.4}\n", .{stats.selectivity});
            try analysis.writer().print("  Access Count: {d}\n", .{stats.access_count});
            try analysis.writer().print("  Hit Ratio: {d:.2}\n", .{stats.hit_ratio});
            try analysis.writer().print("  Avg Key Length: {d:.1}\n", .{stats.avg_key_length});
            
            // Provide recommendations
            if (stats.access_count == 0) {
                unused_indexes += 1;
                try analysis.writer().print("  💡 RECOMMENDATION: Index is unused - consider dropping\n");
            } else if (stats.hit_ratio < 0.1) {
                inefficient_indexes += 1;
                try analysis.writer().print("  ⚠️  WARNING: Low hit ratio - index may be inefficient\n");
            } else if (stats.selectivity > 0.5) {
                try analysis.writer().print("  ⚠️  WARNING: Poor selectivity - consider adding more properties\n");
            } else if (stats.selectivity < 0.01) {
                try analysis.writer().print("  ✅ EXCELLENT: High selectivity index\n");
            }
            
            try analysis.writer().print("\n");
        }
        
        try analysis.writer().print("Summary:\n");
        try analysis.writer().print("  Total Indexes: {d}\n", .{total_indexes});
        try analysis.writer().print("  Unused Indexes: {d}\n", .{unused_indexes});
        try analysis.writer().print("  Inefficient Indexes: {d}\n", .{inefficient_indexes});
        
        if (unused_indexes > 0) {
            try analysis.writer().print("  💡 Consider dropping {d} unused indexes to save storage\n", .{unused_indexes});
        }
        if (inefficient_indexes > 0) {
            try analysis.writer().print("  💡 Consider redesigning {d} inefficient indexes\n", .{inefficient_indexes});
        }
        
        return analysis.toOwnedSlice();
    }
};