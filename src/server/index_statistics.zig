const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const Allocator = std.mem.Allocator;
const geode = @import("geode");
const graph_common = geode.graph_common;

// Index statistics collection for better cost estimation
// CANARY: REQ=REQ-GQL-016; FEATURE="IndexStatistics"; ASPECT=CostEstimation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_016_IndexStatistics; OWNER=engine; UPDATED=2025-10-03

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

    // Vector-specific statistics
    vector_dimension: ?u16 = null,
    vector_avg_distance: f64 = 0.0,
    vector_knn_queries: u64 = 0,
    vector_avg_k_value: f64 = 0.0,

    // Full-text search specific statistics
    fts_total_documents: u64 = 0,
    fts_avg_document_length: f64 = 0.0,
    fts_vocabulary_size: u64 = 0,
    fts_avg_term_frequency: f64 = 0.0,
    fts_search_queries: u64 = 0,
    fts_avg_score: f64 = 0.0,
    fts_phrase_queries: u64 = 0,
    fts_proximity_queries: u64 = 0,

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
        self.last_accessed = compat_timestamp();

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

    // Record vector K-NN query statistics
    pub fn recordVectorKnnQuery(self: *IndexStatistics, k_value: u64, avg_distance: f64) void {
        if (self.vector_dimension == null) return; // Not a vector index

        self.vector_knn_queries += 1;

        // Update average K value
        const new_k = @as(f64, @floatFromInt(k_value));
        self.vector_avg_k_value = (self.vector_avg_k_value * @as(f64, @floatFromInt(self.vector_knn_queries - 1)) + new_k) / @as(f64, @floatFromInt(self.vector_knn_queries));

        // Update average distance
        self.vector_avg_distance = (self.vector_avg_distance * @as(f64, @floatFromInt(self.vector_knn_queries - 1)) + avg_distance) / @as(f64, @floatFromInt(self.vector_knn_queries));
    }

    // Set vector index parameters (called during index creation)
    pub fn setVectorParameters(self: *IndexStatistics, dimension: u16) void {
        self.vector_dimension = dimension;
    }

    // Estimate vector K-NN search cost based on historical data
    pub fn estimateVectorKnnCost(self: *const IndexStatistics, k_value: u64, collection_size: u64) f64 {
        if (self.vector_dimension == null) return std.math.inf(f64);

        // Base HNSW cost model: O(log(n) * k * dimension_factor)
        const log_n = @log(@as(f64, @floatFromInt(collection_size)));
        const k_factor = @as(f64, @floatFromInt(k_value));
        const dimension_factor = if (self.vector_dimension) |dim| @as(f64, @floatFromInt(dim)) / 128.0 else 1.0;

        var base_cost = 5.0 * log_n * k_factor * dimension_factor;

        // Adjust based on historical query patterns
        if (self.vector_knn_queries > 10) {
            // If historical K values are much different from current, adjust cost
            const k_ratio = k_factor / self.vector_avg_k_value;
            if (k_ratio > 2.0 or k_ratio < 0.5) {
                base_cost *= 1.2; // Penalty for unusual K values
            }
        }

        return base_cost;
    }

    // Get vector index recommendations based on usage patterns
    pub fn getVectorIndexRecommendations(self: *const IndexStatistics) []const u8 {
        if (self.vector_dimension == null) return "";
        if (self.vector_knn_queries < 5) return "Insufficient data for recommendations";

        if (self.vector_avg_k_value > 100) {
            return "Consider using approximate search with lower ef parameter for large K queries";
        } else if (self.vector_avg_k_value < 5) {
            return "Index optimized for small K queries - consider increasing ef_construction for better recall";
        } else {
            return "Vector index usage pattern is optimal";
        }
    }

    // Record full-text search query statistics
    // CANARY: REQ=REQ-GQL-FTS-003; FEATURE="FTS Statistics"; ASPECT=Performance; STATUS=TESTED; TEST=TestCANARY_FTSStatistics; OWNER=fts; UPDATED=2025-10-04
    pub fn recordFtsQuery(self: *IndexStatistics, query_type: FtsQueryType, score: f64, documents_found: u64) void {
        if (self.index_type != .fulltext) return; // Not a full-text index

        self.fts_search_queries += 1;

        // Update average score
        self.fts_avg_score = (self.fts_avg_score * @as(f64, @floatFromInt(self.fts_search_queries - 1)) + score) / @as(f64, @floatFromInt(self.fts_search_queries));

        // Track query types
        switch (query_type) {
            .phrase => self.fts_phrase_queries += 1,
            .proximity => self.fts_proximity_queries += 1,
            .simple => {}, // Just count as general search
        }

        // Update hit ratio for FTS
        if (self.fts_total_documents > 0) {
            const current_hit_ratio = @as(f64, @floatFromInt(documents_found)) / @as(f64, @floatFromInt(self.fts_total_documents));
            self.hit_ratio = (self.hit_ratio * @as(f64, @floatFromInt(self.fts_search_queries - 1)) + current_hit_ratio) / @as(f64, @floatFromInt(self.fts_search_queries));
        }
    }

    // Record document indexing for FTS
    pub fn recordFtsDocument(self: *IndexStatistics, document_length: u64, unique_terms: u64) void {
        if (self.index_type != .fulltext) return; // Not a full-text index

        self.fts_total_documents += 1;

        // Update average document length
        const new_length = @as(f64, @floatFromInt(document_length));
        self.fts_avg_document_length = (self.fts_avg_document_length * @as(f64, @floatFromInt(self.fts_total_documents - 1)) + new_length) / @as(f64, @floatFromInt(self.fts_total_documents));

        // Update vocabulary size (approximate)
        self.fts_vocabulary_size += unique_terms;

        // Update average term frequency
        if (self.fts_total_documents > 0) {
            self.fts_avg_term_frequency = @as(f64, @floatFromInt(self.fts_vocabulary_size)) / @as(f64, @floatFromInt(self.fts_total_documents));
        }
    }

    // Estimate full-text search cost based on query complexity and index statistics
    pub fn estimateFtsCost(self: *const IndexStatistics, query_terms: u64, query_type: FtsQueryType) f64 {
        if (self.index_type != .fulltext) return std.math.inf(f64);

        // Base BM25 scoring cost: O(vocabulary_size * log(documents))
        const log_docs = if (self.fts_total_documents > 1) @log(@as(f64, @floatFromInt(self.fts_total_documents))) else 1.0;
        const vocab_factor = if (self.fts_vocabulary_size > 0) @log(@as(f64, @floatFromInt(self.fts_vocabulary_size))) else 1.0;
        const terms_factor = @as(f64, @floatFromInt(query_terms));

        var base_cost = 20.0 * vocab_factor * log_docs * terms_factor;

        // Adjust based on query type complexity
        base_cost *= switch (query_type) {
            .simple => 1.0,
            .phrase => 1.5, // Phrase queries require position checking
            .proximity => 2.0, // Proximity queries require distance calculations
        };

        // Adjust based on average document length (longer docs = more expensive processing)
        if (self.fts_avg_document_length > 100.0) {
            base_cost *= 1.0 + (self.fts_avg_document_length - 100.0) / 500.0;
        }

        // Adjust based on historical hit ratio
        if (self.fts_search_queries > 10) {
            if (self.hit_ratio > 0.8) {
                base_cost *= 0.9; // High hit ratio means efficient searches
            } else if (self.hit_ratio < 0.2) {
                base_cost *= 1.3; // Low hit ratio means expensive searches
            }
        }

        return base_cost;
    }

    // Get full-text search recommendations based on usage patterns
    pub fn getFtsRecommendations(self: *const IndexStatistics) []const u8 {
        if (self.index_type != .fulltext) return "";
        if (self.fts_search_queries < 5) return "Insufficient data for FTS recommendations";

        if (self.fts_avg_document_length > 1000.0) {
            return "Consider document chunking for better search performance on large documents";
        } else if (self.hit_ratio < 0.3) {
            return "Low hit ratio - consider expanding stop word lists or improving query preprocessing";
        } else if (self.fts_phrase_queries > self.fts_search_queries / 2) {
            return "High phrase query usage - consider optimizing phrase index structures";
        } else if (self.fts_vocabulary_size / self.fts_total_documents > 50.0) {
            return "Large vocabulary per document - consider more aggressive stemming or normalization";
        } else {
            return "Full-text search usage pattern is optimal";
        }
    }

    pub const FtsQueryType = enum {
        simple,
        phrase,
        proximity,
    };

    // Get estimated cost factor based on index characteristics
    pub fn getEstimatedCostFactor(self: *const IndexStatistics) f64 {
        var cost_factor: f64 = 1.0;

        // Adjust based on index type
        cost_factor *= switch (self.index_type) {
            .hash => 0.8, // Hash indexes are generally faster
            .btree => 1.0, // Baseline
            .spatial => 1.3, // Spatial indexes have overhead
            .fulltext => 1.5, // Full-text searches are more expensive
            .vector_f32, .vector => 0.9, // HNSW vector indexes are efficient for K-NN
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
    pub fn createIndexStatistics(self: *IndexStatisticsManager, name: []const u8, index_type: graph_common.IndexType, label: []const u8, properties: []const []const u8) !void {
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
