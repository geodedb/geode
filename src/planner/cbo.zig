const std = @import("std");

// Zig 0.16 compat: std.time.timestamp removed.
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
const planner = @import("../planner.zig");
// NOTE: No direct storage import here (avoids cross-module duplication with
// standalone module builds). Statistics collection is fed through a thin
// duck-typed source (`analyzeTable`) or the StorageStatsProvider vtable
// (`analyzeTableWithProvider`) — both are wired by the caller.

// CANARY: REQ=REQ-GQL-CBO; FEATURE="Cost Based Optimizer"; ASPECT=CoreEngine; STATUS=TESTED; TEST=tests/test_gap0867_cbo_estimates.zig; OWNER=planner; UPDATED=2026-06-10
//
// GAP-0867 (2026-06-10): the former `CostBasedOptimizer` struct (choosePlan,
// DP join enumeration, plan-tree CardinalityEstimator/CostModel) was DELETED.
// It referenced `planner.PlanNode` / `planner.PlannerContext`, neither of
// which exists in ../planner.zig — the code could not compile and survived
// only through Zig's lazy analysis (zero live callers). The live cost-based
// path is `src/server/index_optimizer.zig` (IndexOptimizer) plus the
// per-operator seed model in `src/planner/cost_explain.zig`. What remains
// here is the genuinely shared piece: `StatsRegistry` (used by
// `src/planner/cost_model.zig` and `src/distributed/query_planner.zig`)
// and a truthful `explainEstimateJSON` that derives per-scan-node row
// estimates from collected statistics.

/// Default row estimate for a label scan when no statistics have been
/// collected for that label. Reported as "default_heuristic" in the JSON so
/// consumers can distinguish measured estimates from fallbacks.
pub const default_scan_rows: f64 = 1000.0;
/// Heuristic selectivity applied per WHERE/FILTER clause when no column
/// statistics are available. Reported as "heuristic_selectivity".
pub const default_filter_selectivity: f64 = 0.3;
/// Heuristic average out-degree used for relationship expansion estimates.
/// Reported as "heuristic_avg_degree".
pub const default_avg_degree: f64 = 5.0;

/// Emit EXPLAIN-estimate JSON for a parsed query using real statistics from
/// `registry`. Every MATCH scan node carries an `estimated_rows` value and an
/// `estimate_source` that is truthful about provenance:
///   - "statistics"          — row count collected via analyzeTable /
///                             analyzeTableWithProvider / injectTableStats
///   - "default_heuristic"   — no stats collected for the label
///   - "heuristic_avg_degree" / "heuristic_selectivity" — documented model
///                             constants, not measured values
/// Multiple MATCH chains multiply (cartesian product semantics).
/// Caller owns the returned slice.
pub fn explainEstimateJSON(allocator: std.mem.Allocator, registry: *StatsRegistry, q: planner.ast.Query) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"schema\":\"cbo_explain_estimate.v1\",\"nodes\":[");

    var first_node = true;
    var total_rows: f64 = 1.0;
    var saw_chain = false;

    for (q.match.chains) |chain| {
        // The scan pattern is `head` for single-node chains; for hop chains
        // it is the left node of the first hop.
        var scan_pattern: ?planner.ast.NodePattern = chain.head;
        if (scan_pattern == null and chain.hops.len > 0) scan_pattern = chain.hops[0].left;
        const np = scan_pattern orelse continue;
        saw_chain = true;

        var rows: f64 = default_scan_rows;
        var source: []const u8 = "default_heuristic";
        var label: []const u8 = "";
        if (np.labels.len > 0) {
            label = np.labels[0];
            if (registry.getTableStats(label)) |st| {
                rows = @floatFromInt(st.row_count);
                source = "statistics";
            }
        }
        if (!first_node) try buf.append(allocator, ',');
        first_node = false;
        try buf.print(allocator, "{{\"type\":\"node_scan\",\"label\":\"{s}\",\"estimated_rows\":{d},\"estimate_source\":\"{s}\"}}", .{ label, @as(u64, @intFromFloat(@floor(rows))), source });

        // Each relationship hop expands the pipeline by the (documented)
        // average-degree heuristic; no edge statistics are collected yet.
        for (chain.hops) |_| {
            rows *= default_avg_degree;
            try buf.print(allocator, ",{{\"type\":\"expand\",\"estimated_rows\":{d},\"estimate_source\":\"heuristic_avg_degree\"}}", .{@as(u64, @intFromFloat(@floor(rows)))});
        }
        total_rows *= rows;
    }

    if (!saw_chain) total_rows = 1.0;

    if (q.where_clause != null) {
        total_rows *= default_filter_selectivity;
        if (!first_node) try buf.append(allocator, ',');
        first_node = false;
        try buf.print(allocator, "{{\"type\":\"filter\",\"estimated_rows\":{d},\"estimate_source\":\"heuristic_selectivity\"}}", .{@as(u64, @intFromFloat(@floor(total_rows)))});
    }
    if (q.filter_clause != null) {
        total_rows *= default_filter_selectivity;
        if (!first_node) try buf.append(allocator, ',');
        first_node = false;
        try buf.print(allocator, "{{\"type\":\"filter\",\"estimated_rows\":{d},\"estimate_source\":\"heuristic_selectivity\"}}", .{@as(u64, @intFromFloat(@floor(total_rows)))});
    }

    try buf.print(allocator, "],\"estimated_total_rows\":{d}}}", .{@as(u64, @intFromFloat(@floor(total_rows)))});
    return buf.toOwnedSlice(allocator);
}

pub const StatsRegistry = struct {
    allocator: std.mem.Allocator,
    table_stats: std.StringHashMap(TableStats),
    column_stats: std.StringHashMap(ColumnStats),
    index_stats: std.StringHashMap(IndexStats),

    pub const TableStats = struct {
        row_count: u64,
        page_count: u64,
        avg_row_size: u64,
        last_updated: i64,
    };

    pub const ColumnStats = struct {
        table_name: []const u8,
        column_name: []const u8,
        null_count: u64,
        distinct_count: u64,
        min_value: ?[]const u8,
        max_value: ?[]const u8,
        histogram: ?Histogram,
        frequency_histogram: ?FrequencyHistogram, // For categorical data
        height_balanced_histogram: ?HeightBalancedHistogram, // For numeric data
        hyperloglog: ?HyperLogLog, // For distinct estimation
        correlation: f64, // Correlation with physical order
    };

    pub const IndexStats = struct {
        index_name: []const u8,
        table_name: []const u8,
        columns: []const []const u8,
        unique: bool,
        clustered: bool,
        height: u32,
        leaf_pages: u64,
        distinct_keys: u64,
    };

    pub const Histogram = struct {
        buckets: []const HistogramBucket,
        total_rows: u64,
        bucket_type: HistogramType,
        last_updated: i64,

        pub fn estimateSelectivity(self: *const Histogram, predicate: Predicate) f64 {
            var matching_rows: u64 = 0;

            for (self.buckets) |bucket| {
                if (predicate.matches(bucket)) {
                    matching_rows += bucket.frequency;
                }
            }

            if (self.total_rows == 0) return 0.0;
            return @as(f64, @floatFromInt(matching_rows)) / @as(f64, @floatFromInt(self.total_rows));
        }
    };

    pub const HistogramBucket = struct {
        low_value: []const u8,
        high_value: []const u8,
        frequency: u64,
        distinct_count: u64,
    };

    const Predicate = struct {
        op: enum { eq, ne, lt, le, gt, ge, between, in },
        value: []const u8,

        pub fn matches(self: *const Predicate, bucket: HistogramBucket) bool {
            _ = self;
            _ = bucket;
            // Simplified matching logic
            return true;
        }
    };

    pub const HistogramType = enum {
        equi_width,
        equi_depth,
        frequency,
        height_balanced,
        compressed,
    };

    pub const FrequencyHistogram = struct {
        values: std.StringHashMap(u64), // Value -> frequency
        total_count: u64,

        pub fn init(allocator: std.mem.Allocator) FrequencyHistogram {
            return .{
                .values = std.StringHashMap(u64).init(allocator),
                .total_count = 0,
            };
        }

        pub fn deinit(self: *FrequencyHistogram) void {
            self.values.deinit();
        }

        pub fn addValue(self: *FrequencyHistogram, value: []const u8) !void {
            const result = try self.values.getOrPut(value);
            if (!result.found_existing) {
                result.value_ptr.* = 0;
            }
            result.value_ptr.* += 1;
            self.total_count += 1;
        }

        pub fn getFrequency(self: *const FrequencyHistogram, value: []const u8) u64 {
            return self.values.get(value) orelse 0;
        }

        pub fn estimateSelectivity(self: *const FrequencyHistogram, value: []const u8) f64 {
            if (self.total_count == 0) return 0.0;
            const freq = self.getFrequency(value);
            return @as(f64, @floatFromInt(freq)) / @as(f64, @floatFromInt(self.total_count));
        }
    };

    pub const HeightBalancedHistogram = struct {
        boundaries: []const []const u8,
        frequencies: []const u64,
        avg_frequency: f64,

        pub fn estimateRangeSelectivity(self: *const HeightBalancedHistogram, low_str: []const u8, high_str: []const u8) f64 {
            _ = low_str;
            _ = high_str;

            if (self.frequencies.len == 0) return 0.0;

            // Simplified: estimate based on average frequency
            return self.avg_frequency / @as(f64, @floatFromInt(self.frequencies.len));
        }
    };

    pub const HyperLogLog = struct {
        registers: [16384]u8, // 2^14 registers for 1.04% error
        bias_correction: f64,

        pub fn init() HyperLogLog {
            return .{
                .registers = [_]u8{0} ** 16384,
                .bias_correction = 0.7213 / (1.0 + 1.079 / 16384.0),
            };
        }

        pub fn add(self: *HyperLogLog, value: []const u8) void {
            const hash = std.hash.Wyhash.hash(0, value);
            const j = hash & 0x3FFF; // 14 bits for register index
            const w = hash >> 14;

            // Count leading zeros + 1
            const rho = if (w == 0) 50 else @clz(w) + 1;

            if (rho > self.registers[j]) {
                self.registers[j] = @intCast(rho);
            }
        }

        pub fn estimate(self: *const HyperLogLog) u64 {
            var raw_estimate: f64 = 0;
            var zero_count: u32 = 0;

            for (self.registers) |reg| {
                if (reg == 0) {
                    zero_count += 1;
                }
                raw_estimate += std.math.pow(f64, 2, -@as(f64, @floatFromInt(reg)));
            }

            const alpha = 0.7213 / (1.0 + 1.079 / 16384.0);
            var est_raw = alpha * 16384.0 * 16384.0 / raw_estimate;

            // Small range correction
            if (est_raw <= 2.5 * 16384.0 and zero_count != 0) {
                est_raw = 16384.0 * @log(16384.0 / @as(f64, @floatFromInt(zero_count)));
            }

            return @intFromFloat(est_raw * self.bias_correction);
        }
    };

    // HistogramBucket already defined above

    pub fn init(allocator: std.mem.Allocator) StatsRegistry {
        return .{
            .allocator = allocator,
            .table_stats = std.StringHashMap(TableStats).init(allocator),
            .column_stats = std.StringHashMap(ColumnStats).init(allocator),
            .index_stats = std.StringHashMap(IndexStats).init(allocator),
        };
    }

    pub fn deinit(self: *StatsRegistry) void {
        self.table_stats.deinit();
        self.column_stats.deinit();
        self.index_stats.deinit();
    }

    pub fn updateTableStats(self: *StatsRegistry, table: []const u8, stats: TableStats) !void {
        try self.table_stats.put(table, stats);
    }

    pub fn getTableStats(self: *StatsRegistry, table: []const u8) ?TableStats {
        return self.table_stats.get(table);
    }

    pub fn updateColumnStats(self: *StatsRegistry, key: []const u8, stats: ColumnStats) !void {
        try self.column_stats.put(key, stats);
    }

    pub fn getColumnStats(self: *StatsRegistry, table: []const u8, column: []const u8) ?ColumnStats {
        const key = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ table, column }) catch return null;
        defer self.allocator.free(key);
        return self.column_stats.get(key);
    }

    /// Storage statistics provider interface for CBO integration
    /// GAP-0065: Enables statistics collection without direct storage module coupling
    // CANARY: REQ=REQ-GQL-CBO-STATS-001; FEATURE="CBOStorageProvider"; ASPECT=Statistics; STATUS=EXEMPT; OWNER=planner; UPDATED=2026-01-10
    pub const StorageStatsProvider = struct {
        ctx: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            getRowCount: *const fn (ctx: *anyopaque, table: []const u8) u64,
            getPageCount: *const fn (ctx: *anyopaque, table: []const u8) u64,
            getAvgRowSize: *const fn (ctx: *anyopaque, table: []const u8) u64,
            getDistinctCount: *const fn (ctx: *anyopaque, table: []const u8, column: []const u8) u64,
            getMinValue: *const fn (ctx: *anyopaque, table: []const u8, column: []const u8) ?[]const u8,
            getMaxValue: *const fn (ctx: *anyopaque, table: []const u8, column: []const u8) ?[]const u8,
            getNullCount: *const fn (ctx: *anyopaque, table: []const u8, column: []const u8) u64,
        };

        pub fn getRowCount(self: StorageStatsProvider, table: []const u8) u64 {
            return self.vtable.getRowCount(self.ctx, table);
        }
        pub fn getPageCount(self: StorageStatsProvider, table: []const u8) u64 {
            return self.vtable.getPageCount(self.ctx, table);
        }
        pub fn getAvgRowSize(self: StorageStatsProvider, table: []const u8) u64 {
            return self.vtable.getAvgRowSize(self.ctx, table);
        }
        pub fn getDistinctCount(self: StorageStatsProvider, table: []const u8, column: []const u8) u64 {
            return self.vtable.getDistinctCount(self.ctx, table, column);
        }
        pub fn getMinValue(self: StorageStatsProvider, table: []const u8, column: []const u8) ?[]const u8 {
            return self.vtable.getMinValue(self.ctx, table, column);
        }
        pub fn getMaxValue(self: StorageStatsProvider, table: []const u8, column: []const u8) ?[]const u8 {
            return self.vtable.getMaxValue(self.ctx, table, column);
        }
        pub fn getNullCount(self: StorageStatsProvider, table: []const u8, column: []const u8) u64 {
            return self.vtable.getNullCount(self.ctx, table, column);
        }
    };

    /// Analyze table statistics using injected storage provider
    /// GAP-0065: Enables CBO to collect statistics from storage layer
    pub fn analyzeTableWithProvider(self: *StatsRegistry, table: []const u8, provider: StorageStatsProvider) !void {
        const row_count = provider.getRowCount(table);
        const page_count = provider.getPageCount(table);
        const avg_row_size = provider.getAvgRowSize(table);

        try self.updateTableStats(table, .{
            .row_count = row_count,
            .page_count = page_count,
            .avg_row_size = avg_row_size,
            .last_updated = compat_timestamp(),
        });
    }

    /// Manually inject table statistics (for testing or when provider unavailable)
    pub fn injectTableStats(self: *StatsRegistry, table: []const u8, row_count: u64, page_count: u64, avg_row_size: u64) !void {
        try self.updateTableStats(table, .{
            .row_count = row_count,
            .page_count = page_count,
            .avg_row_size = avg_row_size,
            .last_updated = compat_timestamp(),
        });
    }

    /// Analyze a node label ("table") and record REAL row statistics.
    ///
    /// GAP-0867: previously returned `error.FeatureDisabled`. Now counts live
    /// rows through `source`, which must provide
    /// `rowCountForLabel(label: []const u8) usize` — typically a thin adapter
    /// over `GraphStore.countNodesByLabel(graph, label, tenant)` (kept
    /// duck-typed so this module never imports the storage module; see note
    /// at top of file). `page_count` is derived from the row count using the
    /// same 100-tuples-per-page assumption the cost model uses;
    /// `avg_row_size` is 0 (not collected from the store yet — documented
    /// unknown, not a fabricated value).
    pub fn analyzeTable(self: *StatsRegistry, table: []const u8, source: anytype) !void {
        const row_count: u64 = @intCast(source.rowCountForLabel(table));
        const tuples_per_page: u64 = 100;
        try self.updateTableStats(table, .{
            .row_count = row_count,
            .page_count = (row_count + tuples_per_page - 1) / tuples_per_page,
            .avg_row_size = 0,
            .last_updated = compat_timestamp(),
        });
    }

    fn buildColumnStats(self: *StatsRegistry, table: []const u8, column: []const u8, values: [][]const u8) !ColumnStats {
        // Sort values for histogram construction
        std.sort.heap([]const u8, values, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        // Count distinct values and nulls
        var distinct_count: u64 = 0;
        var null_count: u64 = 0;
        var prev: ?[]const u8 = null;

        for (values) |val| {
            if (val.len == 0) {
                null_count += 1;
            } else if (prev == null or !std.mem.eql(u8, prev.?, val)) {
                distinct_count += 1;
                prev = val;
            }
        }

        // Build histogram
        const histogram = try self.buildHeightBalancedHistogram(values, 100);

        // Build HyperLogLog for cardinality estimation
        var hll = HyperLogLog{ .registers = [_]u8{0} ** 16384, .bias_correction = 1.0 };
        for (values) |val| {
            self.updateHyperLogLog(&hll, val);
        }

        return .{
            .table_name = table,
            .column_name = column,
            .null_count = null_count,
            .distinct_count = distinct_count,
            .min_value = if (values.len > 0) values[0] else null,
            .max_value = if (values.len > 0) values[values.len - 1] else null,
            .histogram = histogram,
            .frequency_histogram = if (distinct_count < 1000) try self.buildFrequencyHistogram(values) else null,
            .height_balanced_histogram = histogram,
            .hyperloglog = hll,
            .correlation = try self.calculateCorrelation(values),
        };
    }

    fn buildHeightBalancedHistogram(self: *StatsRegistry, values: [][]const u8, num_buckets: usize) !?HeightBalancedHistogram {
        if (values.len == 0) return null;

        const bucket_size = values.len / num_buckets;
        if (bucket_size == 0) return null;

        var boundaries = try self.allocator.alloc([]const u8, num_buckets);
        var frequencies = try self.allocator.alloc(u64, num_buckets);

        for (0..num_buckets) |i| {
            const start_idx = i * bucket_size;
            const end_idx = if (i == num_buckets - 1) values.len else (i + 1) * bucket_size;

            boundaries[i] = values[end_idx - 1];
            frequencies[i] = end_idx - start_idx;
        }

        return .{
            .boundaries = boundaries,
            .frequencies = frequencies,
            .avg_frequency = @as(f64, @floatFromInt(values.len)) / @as(f64, @floatFromInt(num_buckets)),
        };
    }

    fn buildFrequencyHistogram(self: *StatsRegistry, values: [][]const u8) !?FrequencyHistogram {
        var freq_map = std.StringHashMap(u64).init(self.allocator);

        for (values) |val| {
            const count = freq_map.get(val) orelse 0;
            try freq_map.put(val, count + 1);
        }

        return .{
            .values = freq_map,
            .total_count = values.len,
        };
    }

    fn updateHyperLogLog(_: *StatsRegistry, hll: *HyperLogLog, value: []const u8) void {
        const hash = std.hash.Wyhash.hash(0, value);
        const j = @as(u14, @truncate(hash)); // First 14 bits for register index
        const w = hash >> 14; // Remaining bits
        const leading_zeros = @clz(w) + 1;

        if (leading_zeros > hll.registers[j]) {
            hll.registers[j] = @as(u8, @intCast(leading_zeros));
        }
    }

    fn calculateCorrelation(_: *StatsRegistry, values: [][]const u8) !f64 {
        if (values.len < 2) return 0.0;

        // Calculate Spearman's rank correlation with physical order
        var sum_d_squared: f64 = 0;
        const n = @as(f64, @floatFromInt(values.len));

        for (values, 0..) |val, physical_pos| {
            // Find logical position (rank in sorted order)
            var logical_pos: usize = 0;
            for (values) |other| {
                if (std.mem.order(u8, other, val) == .lt) {
                    logical_pos += 1;
                }
            }

            const d = @as(f64, @floatFromInt(physical_pos)) - @as(f64, @floatFromInt(logical_pos));
            sum_d_squared += d * d;
        }

        return 1.0 - (6.0 * sum_d_squared) / (n * (n * n - 1.0));
    }
};

test "CBO statistics provider interface" {
    const allocator = std.testing.allocator;

    var registry = StatsRegistry.init(allocator);
    defer registry.deinit();

    // Test manual statistics injection (GAP-0065)
    try registry.injectTableStats("users", 10000, 500, 100);
    try registry.injectTableStats("orders", 50000, 2500, 200);

    // Verify statistics were stored
    const user_stats = registry.getTableStats("users");
    try std.testing.expect(user_stats != null);
    try std.testing.expectEqual(@as(u64, 10000), user_stats.?.row_count);
    try std.testing.expectEqual(@as(u64, 500), user_stats.?.page_count);
    try std.testing.expectEqual(@as(u64, 100), user_stats.?.avg_row_size);

    const order_stats = registry.getTableStats("orders");
    try std.testing.expect(order_stats != null);
    try std.testing.expectEqual(@as(u64, 50000), order_stats.?.row_count);
}

test "analyzeTable records real counts from a duck-typed source" {
    const allocator = std.testing.allocator;

    var registry = StatsRegistry.init(allocator);
    defer registry.deinit();

    const FakeStore = struct {
        pub fn rowCountForLabel(_: @This(), label: []const u8) usize {
            if (std.mem.eql(u8, label, "A")) return 100;
            return 0;
        }
    };
    try registry.analyzeTable("A", FakeStore{});

    const stats = registry.getTableStats("A") orelse return error.StatsMissing;
    try std.testing.expectEqual(@as(u64, 100), stats.row_count);
    try std.testing.expectEqual(@as(u64, 1), stats.page_count);
}
