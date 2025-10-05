const std = @import("std");
const enumerator = @import("enumerator.zig");
const cbo = @import("cbo.zig");

// Advanced cost model with cardinality estimation, selectivity prediction,
// and histogram-based statistics for accurate query planning.
//
// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanCostModelFactors; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_PlanCostModelFactors; BENCH=BenchmarkCANARY_REQ_GQL_024_PlanCostModelVarianceEnvelope; OWNER=planner; UPDATED=2025-09-25

pub const CostFactors = struct {
    // CPU costs (per tuple)
    cpu_tuple_cost: f64 = 0.01,
    cpu_index_tuple_cost: f64 = 0.005,
    cpu_operator_cost: f64 = 0.0025,

    // I/O costs (per page)
    seq_page_cost: f64 = 1.0,
    random_page_cost: f64 = 4.0,

    // Operator base costs
    scan_base: f64 = 1.0,
    index_scan_base: f64 = 0.5,
    filter_base: f64 = 0.5,
    project_base: f64 = 0.2,
    join_base: f64 = 4.0,
    hash_join_base: f64 = 3.0,
    merge_join_base: f64 = 2.5,
    nested_loop_base: f64 = 5.0,
    aggregate_base: f64 = 2.5,
    hash_aggregate_base: f64 = 2.0,
    sort_base: f64 = 3.5,
    limit_base: f64 = 0.1,

    // Memory costs
    work_mem: f64 = 4096.0, // KB
    hash_mem_factor: f64 = 1.5,
    sort_mem_factor: f64 = 2.0,

    // Network costs (for distributed)
    network_latency: f64 = 0.1,
    network_bandwidth: f64 = 1000.0, // MB/s

    // Parallelism factors
    parallel_setup_cost: f64 = 1000.0,
    parallel_tuple_cost: f64 = 0.1,
    max_parallel_workers: u32 = 4,

    // Join selectivity defaults
    default_join_selectivity: f64 = 0.01,
    foreign_key_selectivity: f64 = 1.0,

    // Row production penalty multiplier per estimated 1k rows
    per_k_rows: f64 = 0.05,
    // Join depth exponential dampener
    join_depth_penalty: f64 = 1.15,

    // Adaptive factors (learned from execution)
    learned_scan_factor: f64 = 1.0,
    learned_join_factor: f64 = 1.0,
    confidence: f64 = 0.9,
};

pub const CostModel = struct {
    allocator: std.mem.Allocator,
    factors: CostFactors,
    stats_registry: *cbo.StatsRegistry,
    cardinality_estimator: *CardinalityEstimator,

    pub fn init(allocator: std.mem.Allocator, stats: *cbo.StatsRegistry) CostModel {
        const card_est = allocator.create(CardinalityEstimator) catch unreachable;
        card_est.* = CardinalityEstimator.init(allocator, stats);

        return .{
            .allocator = allocator,
            .factors = CostFactors{},
            .stats_registry = stats,
            .cardinality_estimator = card_est,
        };
    }

    pub fn deinit(self: *CostModel) void {
        self.allocator.destroy(self.cardinality_estimator);
    }

    pub fn estimateCost(self: *CostModel, plan: *enumerator.LogicalPlan) !f64 {
        const result = try self.walkPlan(plan, 0);
        return result.total_cost;
    }

    fn walkPlan(self: *CostModel, node: *enumerator.LogicalPlan, depth: usize) !CostEstimate {
        var estimate = CostEstimate{
            .rows = 1.0,
            .width = 100,
            .startup_cost = 0.0,
            .total_cost = 0.0,
            .memory_usage = 0.0,
        };

        switch (node.op) {
            .scan => {
                estimate = try self.estimateScanCost(node);
            },
            .filter => {
                const child = try self.walkPlan(node.children[0], depth + 1);
                estimate = try self.estimateFilterCost(node, child);
            },
            .project => {
                const child = try self.walkPlan(node.children[0], depth + 1);
                estimate = self.estimateProjectCost(node, child);
            },
            .join => {
                const left = try self.walkPlan(node.children[0], depth + 1);
                const right = try self.walkPlan(node.children[1], depth + 1);
                estimate = try self.estimateJoinCost(node, left, right);
            },
            .aggregate => {
                const child = try self.walkPlan(node.children[0], depth + 1);
                estimate = try self.estimateAggregateCost(node, child);
            },
            .sort => {
                const child = try self.walkPlan(node.children[0], depth + 1);
                estimate = self.estimateSortCost(node, child);
            },
            .limit => {
                const child = try self.walkPlan(node.children[0], depth + 1);
                estimate = self.estimateLimitCost(node, child);
            },
        }

        // Apply join depth penalty
        if (depth > 2) {
            const penalty = std.math.pow(f64, self.factors.join_depth_penalty, @as(f64, @floatFromInt(depth - 2)));
            estimate.total_cost *= penalty;
        }

        return estimate;
    }

    fn estimateScanCost(self: *CostModel, node: *enumerator.LogicalPlan) !CostEstimate {
        const table_name = node.table_name orelse "unknown";
        const stats = self.stats_registry.getTableStats(table_name);

        const rows = if (stats) |s| @as(f64, @floatFromInt(s.row_count)) else 1000.0;
        const pages = if (stats) |s| @as(f64, @floatFromInt(s.page_count)) else 10.0;

        // Check if we can use an index
        if (node.index_hint) |index| {
            const index_stats = self.stats_registry.index_stats.get(index);
            if (index_stats) |idx| {
                const index_selectivity = self.estimateIndexSelectivity(node, idx);
                const index_rows = rows * index_selectivity;
                const index_pages = @as(f64, @floatFromInt(idx.leaf_pages)) * index_selectivity;

                return CostEstimate{
                    .rows = index_rows,
                    .width = 100,
                    .startup_cost = self.factors.index_scan_base,
                    .total_cost = self.factors.index_scan_base +
                        index_pages * self.factors.random_page_cost +
                        index_rows * self.factors.cpu_index_tuple_cost,
                    .memory_usage = 0,
                };
            }
        }

        // Sequential scan
        return CostEstimate{
            .rows = rows,
            .width = if (stats) |s| @intCast(s.avg_row_size) else 100,
            .startup_cost = self.factors.scan_base,
            .total_cost = self.factors.scan_base +
                pages * self.factors.seq_page_cost +
                rows * self.factors.cpu_tuple_cost,
            .memory_usage = 0,
        };
    }

    fn estimateFilterCost(self: *CostModel, node: *enumerator.LogicalPlan, child: CostEstimate) !CostEstimate {
        const selectivity = try self.estimateSelectivity(node.predicate);

        return CostEstimate{
            .rows = child.rows * selectivity,
            .width = child.width,
            .startup_cost = child.startup_cost,
            .total_cost = child.total_cost +
                child.rows * self.factors.cpu_operator_cost,
            .memory_usage = child.memory_usage,
        };
    }

    fn estimateJoinCost(self: *CostModel, node: *enumerator.LogicalPlan, left: CostEstimate, right: CostEstimate) !CostEstimate {
        const join_selectivity = try self.estimateJoinSelectivity(node, left, right);
        const result_rows = left.rows * right.rows * join_selectivity;

        var cost: f64 = 0;
        var memory: f64 = 0;

        // Choose join algorithm based on sizes
        if (right.rows < 1000 and right.rows * @as(f64, @floatFromInt(right.width)) < self.factors.work_mem * 1024) {
            // Hash join
            memory = right.rows * @as(f64, @floatFromInt(right.width)) * self.factors.hash_mem_factor / 1024.0;
            cost = left.total_cost + right.total_cost +
                self.factors.hash_join_base +
                (left.rows + right.rows) * self.factors.cpu_operator_cost;
        } else if (node.is_sorted) {
            // Merge join
            cost = left.total_cost + right.total_cost +
                self.factors.merge_join_base +
                (left.rows + right.rows) * self.factors.cpu_operator_cost;
        } else {
            // Nested loop join
            cost = left.total_cost + right.total_cost +
                self.factors.nested_loop_base +
                left.rows * right.rows * self.factors.cpu_operator_cost;
        }

        return CostEstimate{
            .rows = result_rows,
            .width = left.width + right.width,
            .startup_cost = left.startup_cost + right.startup_cost + self.factors.join_base,
            .total_cost = cost,
            .memory_usage = memory,
        };
    }

    fn estimateAggregateCost(self: *CostModel, node: *enumerator.LogicalPlan, child: CostEstimate) !CostEstimate {
        _ = node;
        const groups = @max(1, @as(u64, @intFromFloat(child.rows * 0.1))); // Assume 10% distinct values
        const memory = @as(f64, @floatFromInt(groups * 64)) / 1024.0; // 64 bytes per group

        const use_hash = memory < self.factors.work_mem;
        const base_cost = if (use_hash) self.factors.hash_aggregate_base else self.factors.aggregate_base;

        return CostEstimate{
            .rows = @as(f64, @floatFromInt(groups)),
            .width = 100,
            .startup_cost = child.startup_cost + base_cost,
            .total_cost = child.total_cost + base_cost + child.rows * self.factors.cpu_operator_cost,
            .memory_usage = if (use_hash) memory else 0,
        };
    }

    fn estimateSortCost(self: *CostModel, node: *enumerator.LogicalPlan, child: CostEstimate) CostEstimate {
        _ = node;
        const memory = child.rows * @as(f64, @floatFromInt(child.width)) * self.factors.sort_mem_factor / 1024.0;
        const use_quicksort = memory < self.factors.work_mem;

        const comparison_cost = child.rows * @log2(child.rows + 1) * self.factors.cpu_operator_cost;
        const disk_cost = if (!use_quicksort) memory / 1024.0 * self.factors.seq_page_cost else 0;

        return CostEstimate{
            .rows = child.rows,
            .width = child.width,
            .startup_cost = child.total_cost + self.factors.sort_base,
            .total_cost = child.total_cost + self.factors.sort_base + comparison_cost + disk_cost,
            .memory_usage = @min(memory, self.factors.work_mem),
        };
    }

    fn estimateLimitCost(self: *CostModel, node: *enumerator.LogicalPlan, child: CostEstimate) CostEstimate {
        const limit = node.limit orelse 10;
        const fraction = @min(1.0, @as(f64, @floatFromInt(limit)) / child.rows);

        return CostEstimate{
            .rows = @as(f64, @floatFromInt(limit)),
            .width = child.width,
            .startup_cost = child.startup_cost,
            .total_cost = child.startup_cost + (child.total_cost - child.startup_cost) * fraction + self.factors.limit_base,
            .memory_usage = child.memory_usage,
        };
    }

    fn estimateProjectCost(self: *CostModel, node: *enumerator.LogicalPlan, child: CostEstimate) CostEstimate {
        _ = node;
        return CostEstimate{
            .rows = child.rows,
            .width = 80, // Assume projection reduces width
            .startup_cost = child.startup_cost,
            .total_cost = child.total_cost + child.rows * self.factors.cpu_operator_cost * 0.5,
            .memory_usage = child.memory_usage,
        };
    }

    fn estimateSelectivity(self: *CostModel, predicate: ?*enumerator.Predicate) !f64 {
        if (predicate == null) return 1.0;

        // Use histogram if available
        if (predicate.?.column) |col| {
            if (predicate.?.table) |tbl| {
                if (self.stats_registry.getColumnStats(tbl, col)) |stats| {
                    return self.estimateSelectivityFromHistogram(predicate.?, stats);
                }
            }
        }

        // Default selectivities based on operator
        return switch (predicate.?.op) {
            .eq => 0.005,
            .ne => 0.995,
            .lt, .le, .gt, .ge => 0.333,
            .in => 0.01 * @as(f64, @floatFromInt(predicate.?.values.len)),
            .like => if (std.mem.startsWith(u8, predicate.?.value, "%")) 0.5 else 0.05,
            .between => 0.111,
            .is_null => 0.01,
            .is_not_null => 0.99,
            else => 0.5,
        };
    }

    fn estimateSelectivityFromHistogram(self: *CostModel, predicate: enumerator.Predicate, stats: cbo.StatsRegistry.ColumnStats) f64 {

        // Use frequency histogram for equality
        if (predicate.op == .eq) {
            if (stats.frequency_histogram) |freq| {
                if (freq.values.get(predicate.value)) |count| {
                    return @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(freq.total_count));
                }
            }
            // Uniform distribution assumption
            return 1.0 / @as(f64, @floatFromInt(stats.distinct_count));
        }

        // Use height-balanced histogram for range queries
        if (stats.height_balanced_histogram) |hist| {
            switch (predicate.op) {
                .lt, .le => {
                    var cumulative: f64 = 0;
                    for (hist.boundaries, hist.frequencies) |boundary, freq| {
                        if (std.mem.order(u8, boundary, predicate.value) == .lt) {
                            cumulative += @as(f64, @floatFromInt(freq));
                        } else {
                            // Interpolate within bucket
                            cumulative += @as(f64, @floatFromInt(freq)) * 0.5;
                            break;
                        }
                    }
                    const total = hist.frequencies.len * hist.avg_frequency;
                    return cumulative / total;
                },
                .gt, .ge => {
                    var cumulative: f64 = 0;
                    for (hist.boundaries, hist.frequencies) |boundary, freq| {
                        if (std.mem.order(u8, boundary, predicate.value) == .gt) {
                            cumulative += @as(f64, @floatFromInt(freq));
                        }
                    }
                    const total = hist.frequencies.len * hist.avg_frequency;
                    return cumulative / total;
                },
                .between => {
                    const low_sel = self.estimateSelectivityFromHistogram(.{ .op = .ge, .value = predicate.value, .column = predicate.column, .table = predicate.table }, stats);
                    const high_sel = self.estimateSelectivityFromHistogram(.{ .op = .le, .value = predicate.value2.?, .column = predicate.column, .table = predicate.table }, stats);
                    return low_sel * high_sel;
                },
                else => return 0.5,
            }
        }

        return 0.5; // Fallback
    }

    fn estimateJoinSelectivity(self: *CostModel, node: *enumerator.LogicalPlan, left: CostEstimate, right: CostEstimate) !f64 {

        // Foreign key join
        if (node.is_foreign_key_join) {
            return self.factors.foreign_key_selectivity / @max(left.rows, right.rows);
        }

        // Estimate based on column statistics
        if (node.join_columns) |cols| {
            var min_distinct: f64 = 1e9;
            for (cols) |col| {
                if (self.stats_registry.getColumnStats(col.table, col.column)) |stats| {
                    min_distinct = @min(min_distinct, @as(f64, @floatFromInt(stats.distinct_count)));
                }
            }
            if (min_distinct < 1e9) {
                return 1.0 / min_distinct;
            }
        }

        // Default selectivity
        return self.factors.default_join_selectivity / @max(left.rows, right.rows);
    }

    fn estimateIndexSelectivity(self: *CostModel, node: *enumerator.LogicalPlan, index: cbo.StatsRegistry.IndexStats) f64 {
        _ = self; // not used yet (future adaptive adjustments)

        // Unique index with equality predicate
        if (index.unique and node.predicate) |pred| {
            if (pred.op == .eq) {
                return 1.0 / @as(f64, @floatFromInt(index.distinct_keys));
            }
        }

        // Range query on clustered index
        if (index.clustered) {
            return 0.1; // 10% selectivity for clustered index range scan
        }

        return 0.05; // 5% for non-clustered index
    }
};

pub const CostEstimate = struct {
    rows: f64,
    width: u32, // Average row width in bytes
    startup_cost: f64,
    total_cost: f64,
    memory_usage: f64, // In KB
};

pub const CardinalityEstimator = struct {
    allocator: std.mem.Allocator,
    stats_registry: *cbo.StatsRegistry,

    pub fn init(allocator: std.mem.Allocator, stats: *cbo.StatsRegistry) CardinalityEstimator {
        return .{
            .allocator = allocator,
            .stats_registry = stats,
        };
    }

    pub fn estimateCardinality(self: *CardinalityEstimator, node: *enumerator.LogicalPlan) !f64 {
        return switch (node.op) {
            .scan => try self.estimateScanCardinality(node),
            .filter => try self.estimateFilterCardinality(node),
            .join => try self.estimateJoinCardinality(node),
            .project => try self.estimateProjectCardinality(node),
            .aggregate => try self.estimateAggregateCardinality(node),
            .sort => try self.estimateSortCardinality(node),
            .limit => try self.estimateLimitCardinality(node),
            else => 1000.0, // fallback for unhandled types
        };
    }

    fn estimateScanCardinality(self: *CardinalityEstimator, node: *enumerator.LogicalPlan) !f64 {
        _ = node;
        // Try to get table statistics from registry
        const table_name = "default_table"; // Would extract from node
        if (self.stats_registry.getTableStats(table_name)) |stats| {
            return @floatFromInt(stats.row_count);
        }
        // Default estimate for unknown tables
        return 1000.0;
    }

    fn estimateFilterCardinality(self: *CardinalityEstimator, node: *enumerator.LogicalPlan) !f64 {
        // Get child cardinality
        const child_cardinality = if (node.children.len > 0) 
            try self.estimateCardinality(&node.children[0])
        else 
            1000.0;

        // Apply selectivity based on predicate type
        const selectivity = self.estimateFilterSelectivity(node);
        return child_cardinality * selectivity;
    }

    fn estimateJoinCardinality(self: *CardinalityEstimator, node: *enumerator.LogicalPlan) !f64 {
        if (node.children.len < 2) return 1000.0;

        const left_cardinality = try self.estimateCardinality(&node.children[0]);
        const right_cardinality = try self.estimateCardinality(&node.children[1]);

        // Apply join selectivity estimation
        const join_selectivity = self.estimateJoinSelectivity(node);
        return left_cardinality * right_cardinality * join_selectivity;
    }

    fn estimateProjectCardinality(self: *CardinalityEstimator, node: *enumerator.LogicalPlan) !f64 {
        // Projection doesn't change cardinality
        if (node.children.len > 0) {
            return try self.estimateCardinality(&node.children[0]);
        }
        return 1000.0;
    }

    fn estimateAggregateCardinality(self: *CardinalityEstimator, node: *enumerator.LogicalPlan) !f64 {
        if (node.children.len == 0) return 1.0;

        const child_cardinality = try self.estimateCardinality(&node.children[0]);
        
        // If no GROUP BY, result is 1 row
        // If GROUP BY exists, estimate distinct groups
        if (self.hasGroupBy(node)) {
            // Estimate distinct groups (simplified)
            const group_factor = 0.1; // Assume 10% distinct groups
            return child_cardinality * group_factor;
        }
        return 1.0;
    }

    fn estimateSortCardinality(self: *CardinalityEstimator, node: *enumerator.LogicalPlan) !f64 {
        // Sort doesn't change cardinality
        if (node.children.len > 0) {
            return try self.estimateCardinality(&node.children[0]);
        }
        return 1000.0;
    }

    fn estimateLimitCardinality(self: *CardinalityEstimator, node: *enumerator.LogicalPlan) !f64 {
        if (node.children.len == 0) return 0.0;

        const child_cardinality = try self.estimateCardinality(&node.children[0]);
        const limit_value = self.extractLimitValue(node);
        
        return @min(child_cardinality, @as(f64, @floatFromInt(limit_value)));
    }

    fn estimateFilterSelectivity(self: *CardinalityEstimator, node: *enumerator.LogicalPlan) f64 {
        _ = self;
        _ = node;
        // Simplified selectivity estimation
        // Would analyze predicate type and use statistics
        return 0.1; // Default 10% selectivity
    }

    fn estimateJoinSelectivity(self: *CardinalityEstimator, node: *enumerator.LogicalPlan) f64 {
        _ = self;
        _ = node;
        // Simplified join selectivity estimation
        // Would analyze join conditions and foreign key relationships
        return 0.01; // Default 1% selectivity
    }

    fn hasGroupBy(self: *CardinalityEstimator, node: *enumerator.LogicalPlan) bool {
        _ = self;
        _ = node;
        // Would check if node has GROUP BY clauses
        return false; // Simplified
    }

    fn extractLimitValue(self: *CardinalityEstimator, node: *enumerator.LogicalPlan) u64 {
        _ = self;
        _ = node;
        // Would extract LIMIT value from node
        return 100; // Default limit
    }
};

pub fn estimatePlanCost(root: enumerator.LogicalPlan, factors: CostFactors) f64 {
    return walk(root, factors, 0).cost;
}

// Apply calibration-adjusted factors (if provided) and return cost.
pub fn estimateWithCalibration(root: enumerator.LogicalPlan, base: CostFactors, maybe_cal: ?*const @import("cost_calibration.zig").Calibration) f64 {
    var f = base;
    if (maybe_cal) |cal| {
        if (cal.applied) {
            f.scan_base = cal.factors.scan_base;
            f.filter_base = cal.factors.filter_base;
            f.project_base = cal.factors.project_base;
            f.join_base = cal.factors.join_base;
            f.aggregate_base = cal.factors.aggregate_base;
            f.sort_base = cal.factors.sort_base;
            f.limit_base = cal.factors.limit_base;
        }
    }
    return estimatePlanCost(root, f);
}

const WalkResult = struct { cost: f64, rows: f64, joins: usize };

fn walk(node: enumerator.LogicalPlan, f: CostFactors, depth: usize) WalkResult {
    const base: f64 = switch (node.op) {
        .scan => f.scan_base,
        .filter => f.filter_base,
        .project => f.project_base,
        .join => f.join_base,
        .aggregate => f.aggregate_base,
        .sort => f.sort_base,
        .limit => f.limit_base,
    };
    if (node.children.len == 0) {
        return .{ .cost = base, .rows = 1.0, .joins = if (node.op == .join) 1 else 0 };
    }
    var total_cost: f64 = base;
    var row_est: f64 = 1.0;
    var joins: usize = if (node.op == .join) 1 else 0;
    for (node.children) |child| {
        const r = walk(child, f, depth + 1);
        total_cost += r.cost;
        row_est *= (1.0 + r.rows * 0.10); // compounding simplistic cardinality growth
        joins += r.joins;
    }
    // Row production penalty normalised per 1k rows
    total_cost += (row_est / 1000.0) * f.per_k_rows;
    // Penalize deeper join chains mildly
    if (joins > 1) {
        total_cost *= std.math.pow(f64, f.join_depth_penalty, @floatFromInt(joins - 1));
    }
    return .{ .cost = total_cost, .rows = row_est, .joins = joins };
}
