const std = @import("std");

/// Index selectivity estimator for cost-based planning decisions
pub const SelectivityEstimator = struct {
    allocator: std.mem.Allocator,
    column_stats: std.StringHashMap(ColumnStats),
    
    const ColumnStats = struct {
        total_rows: usize,
        distinct_values: usize,
        null_count: usize,
        min_value: ?[]const u8,
        max_value: ?[]const u8,
        histogram: ?Histogram,
        
        const Histogram = struct {
            buckets: []Bucket,
            
            const Bucket = struct {
                lower_bound: []const u8,
                upper_bound: []const u8,
                frequency: usize,
                distinct_count: usize,
            };
        };
        
        pub fn eqSelectivity(self: ColumnStats) f64 {
            if (self.distinct_values == 0) return 1.0;
            return 1.0 / @as(f64, @floatFromInt(self.distinct_values));
        }
        
        pub fn rangeSelectivity(self: ColumnStats, lower: ?[]const u8, upper: ?[]const u8) f64 {
            _ = lower;
            _ = upper;
            
            // Simple estimation: assume uniform distribution
            if (self.total_rows == 0) return 0.0;
            
            // For now, return a conservative estimate
            return 0.1; // 10% selectivity for range queries
        }
        
        pub fn nullSelectivity(self: ColumnStats) f64 {
            if (self.total_rows == 0) return 0.0;
            return @as(f64, @floatFromInt(self.null_count)) / @as(f64, @floatFromInt(self.total_rows));
        }
    };
    
    pub fn init(allocator: std.mem.Allocator) SelectivityEstimator {
        return .{
            .allocator = allocator,
            .column_stats = std.StringHashMap(ColumnStats).init(allocator),
        };
    }
    
    pub fn deinit(self: *SelectivityEstimator) void {
        var iter = self.column_stats.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.min_value) |min| self.allocator.free(min);
            if (entry.value_ptr.max_value) |max| self.allocator.free(max);
            if (entry.value_ptr.histogram) |hist| {
                for (hist.buckets) |bucket| {
                    self.allocator.free(bucket.lower_bound);
                    self.allocator.free(bucket.upper_bound);
                }
                self.allocator.free(hist.buckets);
            }
        }
        self.column_stats.deinit();
    }
    
    pub fn updateStats(self: *SelectivityEstimator, column: []const u8, total_rows: usize, distinct_values: usize, null_count: usize) !void {
        const stats = ColumnStats{
            .total_rows = total_rows,
            .distinct_values = distinct_values,
            .null_count = null_count,
            .min_value = null,
            .max_value = null,
            .histogram = null,
        };
        
        try self.column_stats.put(column, stats);
    }
    
    pub fn estimateSelectivity(self: *const SelectivityEstimator, column: []const u8, predicate_type: PredicateType) f64 {
        const stats = self.column_stats.get(column) orelse return 0.1; // Default 10% if no stats
        
        return switch (predicate_type) {
            .Equality => stats.eqSelectivity(),
            .Range => stats.rangeSelectivity(null, null),
            .IsNull => stats.nullSelectivity(),
            .IsNotNull => 1.0 - stats.nullSelectivity(),
        };
    }
    
    pub fn estimateIndexCost(self: *const SelectivityEstimator, column: []const u8, predicate_type: PredicateType, table_size: usize) f64 {
        const selectivity = self.estimateSelectivity(column, predicate_type);
        const selected_rows = selectivity * @as(f64, @floatFromInt(table_size));
        
        // Cost model: log(table_size) for index seek + selected_rows for data access
        const seek_cost = std.math.log(f64, 2, @as(f64, @floatFromInt(table_size + 1)));
        const scan_cost = selected_rows;
        
        return seek_cost + scan_cost;
    }
    
    pub fn shouldUseIndex(self: *const SelectivityEstimator, column: []const u8, predicate_type: PredicateType, table_size: usize) bool {
        const index_cost = self.estimateIndexCost(column, predicate_type, table_size);
        const table_scan_cost = @as(f64, @floatFromInt(table_size));
        
        // Use index if it's at least 10% better than table scan
        return index_cost < table_scan_cost * 0.9;
    }
    
    /// Adaptive estimation: adjust estimates based on actual query results
    pub fn updateEstimateFromActual(self: *SelectivityEstimator, column: []const u8, predicate_type: PredicateType, estimated_rows: usize, actual_rows: usize) !void {
        _ = estimated_rows; // Future: use for error calculation
        
        var stats = self.column_stats.getPtr(column) orelse return;
        
        // Simple adaptive adjustment: blend estimate with actual
        const alpha = 0.1; // Learning rate
        const actual_selectivity = if (stats.total_rows > 0) 
            @as(f64, @floatFromInt(actual_rows)) / @as(f64, @floatFromInt(stats.total_rows))
        else 
            0.0;
            
        switch (predicate_type) {
            .Equality => {
                // Adjust distinct_values estimate
                if (actual_selectivity > 0) {
                    const implied_distinct = @as(usize, @intFromFloat(1.0 / actual_selectivity));
                    const new_distinct = @as(usize, @intFromFloat(
                        @as(f64, @floatFromInt(stats.distinct_values)) * (1.0 - alpha) + 
                        @as(f64, @floatFromInt(implied_distinct)) * alpha
                    ));
                    stats.distinct_values = @max(1, new_distinct);
                }
            },
            else => {
                // For other predicate types, we could maintain separate adjustment factors
            },
        }
    }
};

pub const PredicateType = enum {
    Equality,
    Range,
    IsNull,
    IsNotNull,
};

test "selectivity estimator basic functionality" {
    var estimator = SelectivityEstimator.init(std.testing.allocator);
    defer estimator.deinit();
    
    // Update stats for a column
    try estimator.updateStats("user_id", 1000, 800, 10);
    
    // Test equality selectivity
    const eq_sel = estimator.estimateSelectivity("user_id", .Equality);
    try std.testing.expect(eq_sel > 0.0 and eq_sel < 1.0);
    
    // Test index cost estimation
    const index_cost = estimator.estimateIndexCost("user_id", .Equality, 1000);
    try std.testing.expect(index_cost > 0.0);
    
    // Test index recommendation
    const should_use = estimator.shouldUseIndex("user_id", .Equality, 1000);
    try std.testing.expect(should_use); // High selectivity should recommend index
}

test "selectivity estimator adaptive learning" {
    var estimator = SelectivityEstimator.init(std.testing.allocator);
    defer estimator.deinit();
    
    try estimator.updateStats("category", 1000, 10, 0);
    
    const initial_sel = estimator.estimateSelectivity("category", .Equality);
    
    // Simulate actual query result that differs from estimate
    try estimator.updateEstimateFromActual("category", .Equality, 100, 200);
    
    const updated_sel = estimator.estimateSelectivity("category", .Equality);
    
    // Selectivity should have adjusted (though the change might be small due to learning rate)
    try std.testing.expect(updated_sel != initial_sel);
}