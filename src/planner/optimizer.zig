const std = @import("std");
const Allocator = std.mem.Allocator;

// Cost-based query optimizer with statistics
pub const QueryOptimizer = struct {
    allocator: Allocator,
    stats: *Statistics,
    config: OptimizerConfig,

    pub const OptimizerConfig = struct {
        enable_index_scan: bool = true,
        enable_hash_join: bool = true,
        enable_merge_join: bool = true,
        enable_nested_loop: bool = true,
        cost_threshold_for_parallelism: f64 = 1000.0,
        max_parallel_degree: usize = 4,
    };

    pub const Statistics = struct {
        table_stats: std.StringHashMap(TableStats),
        index_stats: std.StringHashMap(IndexStats),

        pub fn init(allocator: Allocator) Statistics {
            return .{
                .table_stats = std.StringHashMap(TableStats).init(allocator),
                .index_stats = std.StringHashMap(IndexStats).init(allocator),
            };
        }

        pub fn deinit(self: *Statistics) void {
            self.table_stats.deinit();
            self.index_stats.deinit();
        }
    };

    pub const TableStats = struct {
        row_count: u64,
        page_count: u64,
        avg_row_size: u64,
        last_analyzed: i64,
    };

    pub const IndexStats = struct {
        unique_values: u64,
        null_values: u64,
        selectivity: f32,
        height: u32,
        leaf_pages: u64,
    };

    pub const LogicalPlan = union(enum) {
        scan: ScanNode,
        filter: FilterNode,
        join: JoinNode,
        aggregate: AggregateNode,
        sort: SortNode,
        limit: LimitNode,
        project: ProjectNode,
    };

    pub const PhysicalPlan = union(enum) {
        seq_scan: SeqScanNode,
        index_scan: IndexScanNode,
        filter: FilterNode,
        hash_join: HashJoinNode,
        merge_join: MergeJoinNode,
        nested_loop: NestedLoopNode,
        hash_aggregate: HashAggregateNode,
        sort_aggregate: SortAggregateNode,
        sort: SortNode,
        top_n: TopNNode,
        limit: LimitNode,
        project: ProjectNode,
    };

    pub const ScanNode = struct {
        table: []const u8,
        columns: [][]const u8,
    };

    pub const SeqScanNode = struct {
        table: []const u8,
        columns: [][]const u8,
        estimated_rows: u64,
        estimated_cost: f64,
    };

    pub const IndexScanNode = struct {
        table: []const u8,
        index: []const u8,
        columns: [][]const u8,
        predicate: ?Predicate,
        estimated_rows: u64,
        estimated_cost: f64,
    };

    pub const FilterNode = struct {
        child: *LogicalPlan,
        predicate: Predicate,
        estimated_selectivity: f32,
    };

    pub const JoinNode = struct {
        left: *LogicalPlan,
        right: *LogicalPlan,
        join_type: JoinType,
        condition: JoinCondition,
    };

    pub const HashJoinNode = struct {
        left: *PhysicalPlan,
        right: *PhysicalPlan,
        join_type: JoinType,
        condition: JoinCondition,
        build_side: Side,
        estimated_rows: u64,
        estimated_cost: f64,
    };

    pub const MergeJoinNode = struct {
        left: *PhysicalPlan,
        right: *PhysicalPlan,
        join_type: JoinType,
        condition: JoinCondition,
        estimated_rows: u64,
        estimated_cost: f64,
    };

    pub const NestedLoopNode = struct {
        left: *PhysicalPlan,
        right: *PhysicalPlan,
        join_type: JoinType,
        condition: JoinCondition,
        estimated_rows: u64,
        estimated_cost: f64,
    };

    pub const AggregateNode = struct {
        child: *LogicalPlan,
        group_by: [][]const u8,
        aggregates: []AggregateFunc,
    };

    pub const HashAggregateNode = struct {
        child: *PhysicalPlan,
        group_by: [][]const u8,
        aggregates: []AggregateFunc,
        estimated_groups: u64,
        estimated_cost: f64,
    };

    pub const SortAggregateNode = struct {
        child: *PhysicalPlan,
        group_by: [][]const u8,
        aggregates: []AggregateFunc,
        estimated_groups: u64,
        estimated_cost: f64,
    };

    pub const SortNode = struct {
        child: *LogicalPlan,
        order_by: []OrderByExpr,
    };

    pub const TopNNode = struct {
        child: *PhysicalPlan,
        order_by: []OrderByExpr,
        limit: u64,
        estimated_cost: f64,
    };

    pub const LimitNode = struct {
        child: *LogicalPlan,
        limit: u64,
        offset: u64,
    };

    pub const ProjectNode = struct {
        child: *LogicalPlan,
        expressions: []Expression,
    };

    pub const JoinType = enum {
        inner,
        left,
        right,
        full,
        semi,
        anti,
    };

    pub const Side = enum {
        left,
        right,
    };

    pub const JoinCondition = union(enum) {
        equi: struct {
            left_col: []const u8,
            right_col: []const u8,
        },
        theta: Predicate,
    };

    pub const Predicate = union(enum) {
        equals: struct { left: Expression, right: Expression },
        not_equals: struct { left: Expression, right: Expression },
        less_than: struct { left: Expression, right: Expression },
        less_than_or_equal: struct { left: Expression, right: Expression },
        greater_than: struct { left: Expression, right: Expression },
        greater_than_or_equal: struct { left: Expression, right: Expression },
        in: struct { expr: Expression, list: []Expression },
        not_in: struct { expr: Expression, list: []Expression },
        like: struct { expr: Expression, pattern: []const u8 },
        is_null: Expression,
        is_not_null: Expression,
        _and: []Predicate,
        _or: []Predicate,
        _not: *Predicate,
    };

    pub const Expression = union(enum) {
        column: []const u8,
        literal: Value,
        function: struct {
            name: []const u8,
            args: []Expression,
        },
    };

    pub const Value = union(enum) {
        null,
        boolean: bool,
        integer: i64,
        float: f64,
        string: []const u8,
    };

    pub const AggregateFunc = struct {
        function: enum { count, sum, avg, min, max },
        expression: Expression,
        alias: []const u8,
    };

    pub const OrderByExpr = struct {
        expression: Expression,
        ascending: bool,
        nulls_first: bool,
    };

    pub const Cost = struct {
        startup: f64,
        total: f64,
        rows: u64,
    };

    pub fn init(allocator: Allocator, stats: *Statistics, config: OptimizerConfig) QueryOptimizer {
        return .{
            .allocator = allocator,
            .stats = stats,
            .config = config,
        };
    }

    pub fn optimize(self: *QueryOptimizer, logical: LogicalPlan) !PhysicalPlan {
        // Apply logical optimizations first
        const optimized_logical = try self.optimizeLogical(logical);

        // Convert to physical plan
        return try self.toPhysical(optimized_logical);
    }

    fn optimizeLogical(self: *QueryOptimizer, plan: LogicalPlan) !LogicalPlan {
        // Apply rule-based optimizations
        var optimized = plan;

        // Push down filters
        optimized = try self.pushDownFilters(optimized);

        // Push down projections
        optimized = try self.pushDownProjections(optimized);

        // Eliminate unnecessary sorts
        optimized = try self.eliminateSorts(optimized);

        // Merge adjacent filters
        optimized = try self.mergeFilters(optimized);

        return optimized;
    }

    fn toPhysical(self: *QueryOptimizer, logical: LogicalPlan) !PhysicalPlan {
        return switch (logical) {
            .scan => |s| try self.chooseScanMethod(s),
            .filter => |f| .{
                .filter = .{
                    .child = try self.allocator.create(PhysicalPlan),
                    .predicate = f.predicate,
                    .estimated_selectivity = f.estimated_selectivity,
                },
            },
            .join => |j| try self.chooseJoinMethod(j),
            .aggregate => |a| try self.chooseAggregateMethod(a),
            .sort => |s| try self.chooseSortMethod(s),
            .limit => |l| .{
                .limit = .{
                    .child = try self.allocator.create(PhysicalPlan),
                    .limit = l.limit,
                    .offset = l.offset,
                },
            },
            .project => |p| .{
                .project = .{
                    .child = try self.allocator.create(PhysicalPlan),
                    .expressions = p.expressions,
                },
            },
        };
    }

    fn chooseScanMethod(self: *QueryOptimizer, scan: ScanNode) !PhysicalPlan {
        const table_stats = self.stats.table_stats.get(scan.table) orelse {
            // No statistics, use sequential scan
            return .{
                .seq_scan = .{
                    .table = scan.table,
                    .columns = scan.columns,
                    .estimated_rows = 1000, // Default estimate
                    .estimated_cost = 100.0,
                },
            };
        };

        // Check if there's a suitable index
        if (self.config.enable_index_scan) {
            var iter = self.stats.index_stats.iterator();
            while (iter.next()) |entry| {
                if (std.mem.startsWith(u8, entry.key_ptr.*, scan.table)) {
                    const index_stats = entry.value_ptr.*;
                    const index_cost = self.estimateIndexScanCost(index_stats, table_stats);
                    const seq_cost = self.estimateSeqScanCost(table_stats);

                    if (index_cost < seq_cost * 0.8) { // Prefer index if significantly cheaper
                        return .{
                            .index_scan = .{
                                .table = scan.table,
                                .index = entry.key_ptr.*,
                                .columns = scan.columns,
                                .predicate = null,
                                .estimated_rows = table_stats.row_count,
                                .estimated_cost = index_cost,
                            },
                        };
                    }
                }
            }
        }

        // Use sequential scan
        return .{
            .seq_scan = .{
                .table = scan.table,
                .columns = scan.columns,
                .estimated_rows = table_stats.row_count,
                .estimated_cost = self.estimateSeqScanCost(table_stats),
            },
        };
    }

    fn chooseJoinMethod(self: *QueryOptimizer, join: JoinNode) !PhysicalPlan {
        const left_cost = try self.estimatePlanCost(join.left.*);
        const right_cost = try self.estimatePlanCost(join.right.*);

        const left_physical = try self.allocator.create(PhysicalPlan);
        left_physical.* = try self.toPhysical(join.left.*);

        const right_physical = try self.allocator.create(PhysicalPlan);
        right_physical.* = try self.toPhysical(join.right.*);

        // Estimate costs for different join methods
        const hash_cost = self.estimateHashJoinCost(left_cost, right_cost);
        const merge_cost = self.estimateMergeJoinCost(left_cost, right_cost);
        const nested_cost = self.estimateNestedLoopCost(left_cost, right_cost);

        // Choose the cheapest method
        if (self.config.enable_hash_join and hash_cost.total <= merge_cost.total and hash_cost.total <= nested_cost.total) {
            return .{
                .hash_join = .{
                    .left = left_physical,
                    .right = right_physical,
                    .join_type = join.join_type,
                    .condition = join.condition,
                    .build_side = if (left_cost.rows < right_cost.rows) .left else .right,
                    .estimated_rows = hash_cost.rows,
                    .estimated_cost = hash_cost.total,
                },
            };
        } else if (self.config.enable_merge_join and merge_cost.total <= nested_cost.total) {
            return .{
                .merge_join = .{
                    .left = left_physical,
                    .right = right_physical,
                    .join_type = join.join_type,
                    .condition = join.condition,
                    .estimated_rows = merge_cost.rows,
                    .estimated_cost = merge_cost.total,
                },
            };
        } else {
            return .{
                .nested_loop = .{
                    .left = left_physical,
                    .right = right_physical,
                    .join_type = join.join_type,
                    .condition = join.condition,
                    .estimated_rows = nested_cost.rows,
                    .estimated_cost = nested_cost.total,
                },
            };
        }
    }

    fn chooseAggregateMethod(self: *QueryOptimizer, agg: AggregateNode) !PhysicalPlan {
        const child_cost = try self.estimatePlanCost(agg.child.*);
        const child_physical = try self.allocator.create(PhysicalPlan);
        child_physical.* = try self.toPhysical(agg.child.*);

        const estimated_groups = self.estimateDistinctValues(agg.group_by, child_cost.rows);

        // Choose between hash and sort aggregate
        const hash_cost = self.estimateHashAggregateCost(child_cost, estimated_groups);
        const sort_cost = self.estimateSortAggregateCost(child_cost, estimated_groups);

        if (hash_cost < sort_cost) {
            return .{
                .hash_aggregate = .{
                    .child = child_physical,
                    .group_by = agg.group_by,
                    .aggregates = agg.aggregates,
                    .estimated_groups = estimated_groups,
                    .estimated_cost = hash_cost,
                },
            };
        } else {
            return .{
                .sort_aggregate = .{
                    .child = child_physical,
                    .group_by = agg.group_by,
                    .aggregates = agg.aggregates,
                    .estimated_groups = estimated_groups,
                    .estimated_cost = sort_cost,
                },
            };
        }
    }

    fn chooseSortMethod(self: *QueryOptimizer, sort: SortNode) !PhysicalPlan {
        const child_cost = try self.estimatePlanCost(sort.child.*);
        const child_physical = try self.allocator.create(PhysicalPlan);
        child_physical.* = try self.toPhysical(sort.child.*);

        // Check if there's a LIMIT that would benefit from top-N sort
        if (sort.child.* == .limit) {
            const limit = sort.child.limit;
            if (limit.limit < child_cost.rows / 10) { // Use top-N if selecting < 10%
                return .{
                    .top_n = .{
                        .child = child_physical,
                        .order_by = sort.order_by,
                        .limit = limit.limit,
                        .estimated_cost = self.estimateTopNSortCost(child_cost, limit.limit),
                    },
                };
            }
        }

        return .{
            .sort = .{
                .child = child_physical,
                .order_by = sort.order_by,
            },
        };
    }

    fn estimatePlanCost(self: *QueryOptimizer, plan: LogicalPlan) !Cost {
        return switch (plan) {
            .scan => |s| {
                const stats = self.stats.table_stats.get(s.table) orelse {
                    return Cost{ .startup = 0, .total = 100, .rows = 1000 };
                };
                return Cost{
                    .startup = 0,
                    .total = self.estimateSeqScanCost(stats),
                    .rows = stats.row_count,
                };
            },
            .filter => |f| {
                const child_cost = try self.estimatePlanCost(f.child.*);
                return Cost{
                    .startup = child_cost.startup,
                    .total = child_cost.total * 1.1,
                    .rows = @as(u64, @intFromFloat(@as(f64, @floatFromInt(child_cost.rows)) * f.estimated_selectivity)),
                };
            },
            else => Cost{ .startup = 0, .total = 1000, .rows = 1000 },
        };
    }

    fn estimateSeqScanCost(self: *QueryOptimizer, stats: TableStats) f64 {
        _ = self;
        // Cost = disk pages + CPU per row
        return @as(f64, @floatFromInt(stats.page_count)) * 1.0 +
            @as(f64, @floatFromInt(stats.row_count)) * 0.01;
    }

    fn estimateIndexScanCost(self: *QueryOptimizer, index: IndexStats, table: TableStats) f64 {
        _ = self;
        // Cost = index pages + table pages for matching rows
        const matching_rows = @as(f64, @floatFromInt(table.row_count)) * index.selectivity;
        return @as(f64, @floatFromInt(index.height)) +
            @as(f64, @floatFromInt(index.leaf_pages)) * index.selectivity +
            matching_rows * 1.5; // Random I/O penalty
    }

    fn estimateHashJoinCost(self: *QueryOptimizer, left: Cost, right: Cost) Cost {
        _ = self;
        // Cost = build hash table + probe
        const build_cost = @min(left.total, right.total) * 1.2;
        const probe_cost = @max(left.total, right.total) * 1.1;
        return Cost{
            .startup = build_cost,
            .total = build_cost + probe_cost,
            .rows = left.rows * right.rows / 100, // Assume 1% selectivity
        };
    }

    fn estimateMergeJoinCost(self: *QueryOptimizer, left: Cost, right: Cost) Cost {
        _ = self;
        // Cost = sort both sides + merge
        const sort_cost = (left.total + right.total) * @log2(@as(f64, @floatFromInt(left.rows + right.rows)));
        return Cost{
            .startup = sort_cost,
            .total = sort_cost + left.total + right.total,
            .rows = left.rows * right.rows / 100,
        };
    }

    fn estimateNestedLoopCost(self: *QueryOptimizer, left: Cost, right: Cost) Cost {
        _ = self;
        // Cost = outer * inner
        return Cost{
            .startup = 0,
            .total = left.total + left.rows * right.total,
            .rows = left.rows * right.rows / 100,
        };
    }

    fn estimateHashAggregateCost(self: *QueryOptimizer, child: Cost, groups: u64) f64 {
        _ = self;
        // Cost = scan + hash table maintenance
        return child.total + @as(f64, @floatFromInt(child.rows)) * 0.02 +
            @as(f64, @floatFromInt(groups)) * 0.05;
    }

    fn estimateSortAggregateCost(self: *QueryOptimizer, child: Cost, groups: u64) f64 {
        _ = self;
        _ = groups;
        // Cost = sort + scan
        return child.total * @log2(@as(f64, @floatFromInt(child.rows))) + child.total;
    }

    fn estimateTopNSortCost(self: *QueryOptimizer, child: Cost, limit: u64) f64 {
        _ = self;
        // Cost = scan with heap maintenance
        return child.total + @as(f64, @floatFromInt(child.rows)) * @log2(@as(f64, @floatFromInt(limit)));
    }

    fn estimateDistinctValues(self: *QueryOptimizer, columns: [][]const u8, total_rows: u64) u64 {
        _ = self;
        // Simple estimate: assume 10% distinct values per column
        const distinct_ratio = std.math.pow(f64, 0.1, @as(f64, @floatFromInt(columns.len)));
        return @as(u64, @intFromFloat(@as(f64, @floatFromInt(total_rows)) * distinct_ratio));
    }

    fn pushDownFilters(self: *QueryOptimizer, plan: LogicalPlan) !LogicalPlan {
        _ = self;
        // Push filters closer to scans
        // This is a simplified version - real implementation would be more complex
        return plan;
    }

    fn pushDownProjections(self: *QueryOptimizer, plan: LogicalPlan) !LogicalPlan {
        _ = self;
        // Eliminate unnecessary columns early
        return plan;
    }

    fn eliminateSorts(self: *QueryOptimizer, plan: LogicalPlan) !LogicalPlan {
        _ = self;
        // Remove redundant sorts
        return plan;
    }

    fn mergeFilters(self: *QueryOptimizer, plan: LogicalPlan) !LogicalPlan {
        _ = self;
        // Combine adjacent filter nodes
        return plan;
    }
};
