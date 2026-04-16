const std = @import("std");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        _ = std.c.getrandom(buf.ptr, buf.len, 0);
    }
}

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

/// HyperLogLog++ sketch for cardinality estimation
const HLLSketch = struct {
    buckets: []u8,
    precision: u8,
    alpha: f64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, precision: u8) !Self {
        const num_buckets = @as(usize, 1) << @intCast(precision);
        const buckets = try allocator.alloc(u8, num_buckets);
        @memset(buckets, 0);

        const alpha = switch (precision) {
            4 => 0.673,
            5 => 0.697,
            6 => 0.709,
            else => 0.7213 / (1.0 + 1.079 / @as(f64, @floatFromInt(num_buckets))),
        };

        return Self{
            .buckets = buckets,
            .precision = precision,
            .alpha = alpha,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.buckets);
    }

    pub fn add(self: *Self, value: []const u8) void {
        const hash = std.hash_map.hashString(value);
        const bucket_idx = hash >> @intCast(64 - self.precision);
        const w = hash << @intCast(self.precision);
        const leading_zeros = @clz(w | 1) + 1;

        if (leading_zeros > self.buckets[bucket_idx]) {
            self.buckets[bucket_idx] = @intCast(leading_zeros);
        }
    }

    pub fn estimate(self: *const Self) f64 {
        const m = @as(f64, @floatFromInt(self.buckets.len));
        var raw_estimate: f64 = 0.0;
        var zero_count: usize = 0;

        for (self.buckets) |bucket| {
            if (bucket == 0) {
                zero_count += 1;
            }
            raw_estimate += std.math.pow(f64, 2.0, -@as(f64, @floatFromInt(bucket)));
        }

        raw_estimate = self.alpha * m * m / raw_estimate;

        // Small range correction
        if (raw_estimate <= 2.5 * m) {
            if (zero_count != 0) {
                return m * std.math.log(f64, std.math.e, m / @as(f64, @floatFromInt(zero_count)));
            }
        }

        // Large range correction
        if (raw_estimate <= (1.0 / 30.0) * std.math.pow(f64, 2.0, 32.0)) {
            return raw_estimate;
        } else {
            return -std.math.pow(f64, 2.0, 32.0) * std.math.log(f64, std.math.e, 1.0 - raw_estimate / std.math.pow(f64, 2.0, 32.0));
        }
    }

    pub fn merge(self: *Self, other: *const Self) void {
        for (self.buckets, 0..) |*bucket, i| {
            bucket.* = @max(bucket.*, other.buckets[i]);
        }
    }
};

/// Adaptive sampling for large datasets
const AdaptiveSampler = struct {
    sample_rate: f64,
    min_sample_size: usize,
    max_sample_size: usize,
    current_sample_size: usize,
    total_seen: usize,

    const Self = @This();

    pub fn init(min_size: usize, max_size: usize) Self {
        return Self{
            .sample_rate = 1.0,
            .min_sample_size = min_size,
            .max_sample_size = max_size,
            .current_sample_size = 0,
            .total_seen = 0,
        };
    }

    pub fn shouldSample(self: *Self) bool {
        self.total_seen += 1;

        if (self.current_sample_size < self.min_sample_size) {
            self.current_sample_size += 1;
            return true;
        }

        if (self.current_sample_size >= self.max_sample_size) {
            // Reservoir sampling
            const rand = blk: {
                var _rf: [8]u8 = undefined;
                compat_fillRandom(&_rf);
                const _ri = std.mem.readInt(u64, &_rf, .little);
                break :blk @as(f64, @floatFromInt(_ri >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
            };
            if (rand < @as(f64, @floatFromInt(self.max_sample_size)) / @as(f64, @floatFromInt(self.total_seen))) {
                return true;
            }
            return false;
        }

        // Adaptive rate adjustment
        const target_rate = @as(f64, @floatFromInt(self.max_sample_size)) / @as(f64, @floatFromInt(self.total_seen));
        self.sample_rate = @min(1.0, target_rate * 1.1); // 10% buffer

        const rand = blk: {
            var _rf: [8]u8 = undefined;
            compat_fillRandom(&_rf);
            const _ri = std.mem.readInt(u64, &_rf, .little);
            break :blk @as(f64, @floatFromInt(_ri >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
        };
        if (rand < self.sample_rate) {
            self.current_sample_size += 1;
            return true;
        }

        return false;
    }

    pub fn getScaleFactor(self: *const Self) f64 {
        if (self.current_sample_size == 0) return 1.0;
        return @as(f64, @floatFromInt(self.total_seen)) / @as(f64, @floatFromInt(self.current_sample_size));
    }
};

/// Index selectivity estimator for cost-based planning decisions
pub const SelectivityEstimator = struct {
    allocator: std.mem.Allocator,
    column_stats: std.StringHashMap(ColumnStats),
    enable_hll: bool,
    enable_adaptive_sampling: bool,

    const ColumnStats = struct {
        total_rows: usize,
        distinct_values: usize,
        null_count: usize,
        min_value: ?[]const u8,
        max_value: ?[]const u8,
        histogram: ?Histogram,
        hll_sketch: ?HLLSketch,
        sampler: ?AdaptiveSampler,
        last_update_time: i64,

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
            // Use HLL estimate if available and more recent
            if (self.hll_sketch) |sketch| {
                const hll_distinct = sketch.estimate();
                if (hll_distinct > 0) {
                    return 1.0 / hll_distinct;
                }
            }

            if (self.distinct_values == 0) return 1.0;
            return 1.0 / @as(f64, @floatFromInt(self.distinct_values));
        }

        pub fn rangeSelectivity(self: ColumnStats, lower: ?[]const u8, upper: ?[]const u8) f64 {
            // Use histogram if available
            if (self.histogram) |hist| {
                return self.histogramRangeSelectivity(hist, lower, upper);
            }

            // Fallback to uniform distribution assumption
            if (self.total_rows == 0) return 0.0;

            // If we have min/max bounds, estimate based on range
            if (self.min_value != null and self.max_value != null and lower != null and upper != null) {
                // Simple string-based range estimation (could be improved with proper type handling)
                const total_range = self.max_value.?.len + self.min_value.?.len; // Simplified
                const query_range = lower.?.len + upper.?.len; // Simplified
                if (total_range > 0) {
                    return @min(1.0, @as(f64, @floatFromInt(query_range)) / @as(f64, @floatFromInt(total_range)));
                }
            }

            // Conservative default
            return 0.1;
        }

        fn histogramRangeSelectivity(self: ColumnStats, hist: Histogram, lower: ?[]const u8, upper: ?[]const u8) f64 {
            _ = self;
            var selectivity: f64 = 0.0;

            for (hist.buckets) |bucket| {
                var bucket_selectivity: f64 = 0.0;

                // Check if bucket overlaps with query range
                const bucket_overlaps = blk: {
                    if (lower != null and std.mem.order(u8, bucket.upper_bound, lower.?) == .lt) {
                        break :blk false;
                    }
                    if (upper != null and std.mem.order(u8, bucket.lower_bound, upper.?) == .gt) {
                        break :blk false;
                    }
                    break :blk true;
                };

                if (bucket_overlaps) {
                    // Simplified: assume uniform distribution within bucket
                    bucket_selectivity = @as(f64, @floatFromInt(bucket.frequency));
                }

                selectivity += bucket_selectivity;
            }

            return selectivity;
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
            .enable_hll = true,
            .enable_adaptive_sampling = true,
        };
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, enable_hll: bool, enable_adaptive_sampling: bool) SelectivityEstimator {
        return .{
            .allocator = allocator,
            .column_stats = std.StringHashMap(ColumnStats).init(allocator),
            .enable_hll = enable_hll,
            .enable_adaptive_sampling = enable_adaptive_sampling,
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
            if (entry.value_ptr.hll_sketch) |*sketch| {
                sketch.deinit(self.allocator);
            }
        }
        self.column_stats.deinit();
    }

    pub fn updateStats(self: *SelectivityEstimator, column: []const u8, total_rows: usize, distinct_values: usize, null_count: usize) !void {
        var stats = ColumnStats{
            .total_rows = total_rows,
            .distinct_values = distinct_values,
            .null_count = null_count,
            .min_value = null,
            .max_value = null,
            .histogram = null,
            .hll_sketch = null,
            .sampler = null,
            .last_update_time = compat_timestamp(),
        };

        // Initialize HLL sketch if enabled
        if (self.enable_hll) {
            stats.hll_sketch = HLLSketch.init(self.allocator, 12) catch null; // 2^12 = 4096 buckets
        }

        // Initialize adaptive sampler if enabled
        if (self.enable_adaptive_sampling) {
            stats.sampler = AdaptiveSampler.init(1000, 10000); // min 1K, max 10K samples
        }

        try self.column_stats.put(column, stats);
    }

    /// Add a value to the column statistics for incremental updates
    pub fn addValue(self: *SelectivityEstimator, column: []const u8, value: []const u8) !void {
        var stats = self.column_stats.getPtr(column) orelse return;

        // Update HLL sketch if available
        if (stats.hll_sketch) |*sketch| {
            // Check if we should sample this value
            var should_add = true;
            if (stats.sampler) |*sampler| {
                should_add = sampler.shouldSample();
            }

            if (should_add) {
                sketch.add(value);
            }
        }

        stats.last_update_time = compat_timestamp();
    }

    /// Get the estimated distinct count using HLL if available
    pub fn getDistinctCount(self: *const SelectivityEstimator, column: []const u8) f64 {
        const stats = self.column_stats.get(column) orelse return 0.0;

        if (stats.hll_sketch) |sketch| {
            var estimate = sketch.estimate();

            // Apply sampling scale factor if using adaptive sampling
            if (stats.sampler) |sampler| {
                estimate *= sampler.getScaleFactor();
            }

            return estimate;
        }

        return @as(f64, @floatFromInt(stats.distinct_values));
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
                    const new_distinct = @as(usize, @intFromFloat(@as(f64, @floatFromInt(stats.distinct_values)) * (1.0 - alpha) +
                        @as(f64, @floatFromInt(implied_distinct)) * alpha));
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

test "HLL sketch cardinality estimation" {
    var sketch = try HLLSketch.init(std.testing.allocator, 12);
    defer sketch.deinit(std.testing.allocator);

    // Add some values
    const values = [_][]const u8{ "a", "b", "c", "d", "e", "a", "b" }; // 5 distinct
    for (values) |value| {
        sketch.add(value);
    }

    const estimate = sketch.estimate();
    // Should be close to 5, allowing for HLL error
    try std.testing.expect(estimate >= 3.0 and estimate <= 7.0);
}

test "adaptive sampler" {
    var sampler = AdaptiveSampler.init(5, 10);

    // First 5 should always be sampled
    var sampled_count: usize = 0;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        if (sampler.shouldSample()) sampled_count += 1;
    }
    try std.testing.expect(sampled_count == 5);

    // After that, sampling should be probabilistic
    while (i < 20) : (i += 1) {
        _ = sampler.shouldSample();
    }

    const scale_factor = sampler.getScaleFactor();
    try std.testing.expect(scale_factor >= 1.0);
}

test "selectivity estimator with HLL" {
    var estimator = SelectivityEstimator.initWithOptions(std.testing.allocator, true, true);
    defer estimator.deinit();

    try estimator.updateStats("test_col", 1000, 100, 0);

    // Add some values to HLL
    try estimator.addValue("test_col", "value1");
    try estimator.addValue("test_col", "value2");
    try estimator.addValue("test_col", "value1"); // duplicate

    const distinct_count = estimator.getDistinctCount("test_col");
    try std.testing.expect(distinct_count > 0.0);
}
