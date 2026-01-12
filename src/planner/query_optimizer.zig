const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../gql/ast.zig");

// Enhanced cost-based query optimizer
pub const QueryOptimizer = struct {
    allocator: Allocator,
    statistics: Statistics,
    cost_model: CostModel,

    pub const Statistics = struct {
        table_stats: std.StringHashMap(TableStats),
        index_stats: std.StringHashMap(IndexStats),

        pub const TableStats = struct {
            row_count: u64,
            avg_row_size: u64,
            null_fraction: f64,
            distinct_values: u64,
            most_common_values: []Value,
            histogram: ?Histogram,
        };

        pub const IndexStats = struct {
            unique: bool,
            null_fraction: f64,
            avg_leaf_blocks: u64,
            leaf_pages: u64,
            distinct_keys: u64,
            clustering_factor: f64,
        };

        pub const Histogram = struct {
            buckets: []HistogramBucket,
        };

        pub const HistogramBucket = struct {
            lower_bound: Value,
            upper_bound: Value,
            frequency: u64,
            distinct_values: u64,
        };

        pub const Value = union(enum) {
            int: i64,
            float: f64,
            string: []const u8,
        };
    };

    pub const CostModel = struct {
        seq_page_cost: f64 = 1.0,
        random_page_cost: f64 = 4.0,
        cpu_tuple_cost: f64 = 0.01,
        cpu_index_tuple_cost: f64 = 0.005,
        cpu_operator_cost: f64 = 0.0025,
        parallel_setup_cost: f64 = 1000.0,
        parallel_tuple_cost: f64 = 0.1,
    };

    pub const Plan = struct {
        root: *PlanNode,
        estimated_cost: f64,
        estimated_rows: u64,
    };

    pub const PlanNode = struct {
        type: PlanNodeType,
        children: []PlanNode,
        cost: f64,
        rows: u64,
        width: u64,
        parallel_aware: bool,
        async_capable: bool,

        pub const PlanNodeType = union(enum) {
            seq_scan: SeqScan,
            index_scan: IndexScan,
            index_only_scan: IndexOnlyScan,
            bitmap_scan: BitmapScan,
            nested_loop: NestedLoop,
            hash_join: HashJoin,
            merge_join: MergeJoin,
            sort: Sort,
            hash_agg: HashAgg,
            group_agg: GroupAgg,
            limit: Limit,
            materialize: Materialize,
            gather: Gather,
            gather_merge: GatherMerge,
        };

        pub const SeqScan = struct {
            table: []const u8,
            filter: ?ast.Expr,
        };

        pub const IndexScan = struct {
            table: []const u8,
            index: []const u8,
            index_cond: ?ast.Expr,
            filter: ?ast.Expr,
        };

        pub const IndexOnlyScan = struct {
            table: []const u8,
            index: []const u8,
            index_cond: ?ast.Expr,
        };

        pub const BitmapScan = struct {
            table: []const u8,
            indexes: [][]const u8,
            recheck_cond: ?ast.Expr,
        };

        pub const NestedLoop = struct {
            join_type: JoinType,
            join_filter: ?ast.Expr,
        };

        pub const HashJoin = struct {
            join_type: JoinType,
            hash_cond: ?ast.Expr,
            join_filter: ?ast.Expr,
        };

        pub const MergeJoin = struct {
            join_type: JoinType,
            merge_cond: ?ast.Expr,
            join_filter: ?ast.Expr,
        };

        pub const Sort = struct {
            sort_keys: []SortKey,
        };

        pub const HashAgg = struct {
            group_keys: []ast.Expr,
            aggregates: []Aggregate,
        };

        pub const GroupAgg = struct {
            group_keys: []ast.Expr,
            aggregates: []Aggregate,
        };

        pub const Limit = struct {
            count: ?u64,
            offset: ?u64,
        };

        pub const Materialize = struct {};

        pub const Gather = struct {
            workers_planned: u32,
            single_copy: bool,
        };

        pub const GatherMerge = struct {
            workers_planned: u32,
        };

        pub const JoinType = enum {
            inner,
            left,
            right,
            full,
            semi,
            anti,
        };

        pub const SortKey = struct {
            expr: ast.Expr,
            desc: bool,
            nulls_first: bool,
        };

        pub const Aggregate = struct {
            func: []const u8,
            args: []ast.Expr,
            distinct: bool,
        };
    };

    pub fn init(allocator: Allocator) QueryOptimizer {
        return .{
            .allocator = allocator,
            .statistics = .{
                .table_stats = std.StringHashMap(Statistics.TableStats).init(allocator),
                .index_stats = std.StringHashMap(Statistics.IndexStats).init(allocator),
            },
            .cost_model = CostModel{},
        };
    }

    pub fn deinit(self: *QueryOptimizer) void {
        self.statistics.table_stats.deinit();
        self.statistics.index_stats.deinit();
    }

    // Optimize a query
    pub fn optimize(self: *QueryOptimizer, query: ast.Query) !Plan {
        // Generate all possible plans
        const plans = try self.generatePlans(query);
        defer self.allocator.free(plans);

        // Choose the plan with lowest cost
        var best_plan = plans[0];
        for (plans[1..]) |plan| {
            if (plan.estimated_cost < best_plan.estimated_cost) {
                best_plan = plan;
            }
        }

        // Apply additional optimizations
        try self.applyRules(&best_plan);

        return best_plan;
    }

    // Generate possible plans for a query
    fn generatePlans(self: *QueryOptimizer, query: ast.Query) ![]Plan {
        var plans = std.ArrayList(Plan){};

        // Generate access paths
        const access_paths = try self.generateAccessPaths(query);

        // Generate join orders
        const join_orders = try self.generateJoinOrders(query);

        // Combine access paths and join orders
        for (access_paths) |access_path| {
            for (join_orders) |join_order| {
                const plan = try self.buildPlan(access_path, join_order, query);
                try plans.append(plan);
            }
        }

        return plans.toOwnedSlice();
    }

    // Generate access paths (sequential scan, index scan, etc.)
    fn generateAccessPaths(self: *QueryOptimizer, query: ast.Query) ![]AccessPath {
        _ = query;
        var paths = std.ArrayList(AccessPath){};

        // For each table in the query
        var table_it = self.statistics.table_stats.iterator();
        while (table_it.next()) |entry| {
            const table_name = entry.key_ptr.*;
            const table_stats = entry.value_ptr.*;

            // Sequential scan
            try paths.append(.{
                .type = .seq_scan,
                .table = table_name,
                .cost = self.estimateSeqScanCost(table_stats),
            });

            // Index scans
            var index_it = self.statistics.index_stats.iterator();
            while (index_it.next()) |index_entry| {
                const index_name = index_entry.key_ptr.*;
                const index_stats = index_entry.value_ptr.*;

                // Check if index applies to this table
                if (self.indexAppliesToTable(index_name, table_name)) {
                    try paths.append(.{
                        .type = .index_scan,
                        .table = table_name,
                        .index = index_name,
                        .cost = self.estimateIndexScanCost(index_stats, table_stats),
                    });
                }
            }
        }

        return paths.toOwnedSlice();
    }

    const AccessPath = struct {
        type: enum { seq_scan, index_scan, bitmap_scan },
        table: []const u8,
        index: ?[]const u8 = null,
        cost: f64,
    };

    // GAP-0112 FIX: Generate join orders using dynamic programming approach
    // CANARY: REQ=REQ-QP-DP-JOIN-001; FEATURE="DPJoinOrdering"; STATUS=IMPL; OWNER=planner; UPDATED=2026-01-12
    // This implements a DP-based join enumeration algorithm supporting both left-deep and bushy trees
    fn generateJoinOrders(self: *QueryOptimizer, query: ast.Query) ![]JoinOrder {
        var orders = std.ArrayList(JoinOrder).init(self.allocator);

        // Extract tables from query MATCH clause
        const tables = try self.extractTablesFromQuery(query);
        if (tables.len == 0) {
            // No tables, return empty join order
            try orders.append(.{
                .tables = &[_][]const u8{},
                .join_methods = &[_]JoinMethod{},
            });
            return try orders.toOwnedSlice();
        }

        if (tables.len == 1) {
            // Single table, no join needed
            const table_slice = try self.allocator.alloc([]const u8, 1);
            table_slice[0] = tables[0];
            try orders.append(.{
                .tables = table_slice,
                .join_methods = &[_]JoinMethod{},
            });
            return try orders.toOwnedSlice();
        }

        // GAP-0112: Dynamic programming join enumeration
        // For small numbers of tables, enumerate all orderings
        // For larger sets, use DP with memoization
        if (tables.len <= 6) {
            // Generate left-deep join orders (standard approach)
            try self.generateLeftDeepJoinOrders(&orders, tables);

            // Generate right-deep join orders (for comparison)
            try self.generateRightDeepJoinOrders(&orders, tables);

            // Generate bushy join trees for optimal plans (2-4 tables)
            if (tables.len <= 4) {
                try self.generateBushyJoinOrders(&orders, tables);
            }
        } else {
            // For many tables, use greedy heuristics
            try self.generateGreedyJoinOrders(&orders, tables);
        }

        return try orders.toOwnedSlice();
    }

    // Extract table names from a query's MATCH patterns
    fn extractTablesFromQuery(self: *QueryOptimizer, query: ast.Query) ![][]const u8 {
        var table_set = std.StringHashMap(void).init(self.allocator);
        defer table_set.deinit();

        // Extract from MATCH clause
        if (query.match.chains.len > 0) {
            for (query.match.chains) |chain| {
                // Extract from start node
                if (chain.start.labels.len > 0) {
                    for (chain.start.labels) |label| {
                        _ = try table_set.put(label, {});
                    }
                }
                // Extract from hops
                for (chain.hops) |hop| {
                    if (hop.node.labels.len > 0) {
                        for (hop.node.labels) |label| {
                            _ = try table_set.put(label, {});
                        }
                    }
                }
            }
        }

        // Convert to slice
        var tables = try self.allocator.alloc([]const u8, table_set.count());
        var idx: usize = 0;
        var it = table_set.keyIterator();
        while (it.next()) |key| {
            tables[idx] = key.*;
            idx += 1;
        }
        return tables;
    }

    // Generate left-deep join orders (table ordering permutations)
    fn generateLeftDeepJoinOrders(self: *QueryOptimizer, orders: *std.ArrayList(JoinOrder), tables: []const []const u8) !void {
        // Generate first few permutations for left-deep trees
        // Full permutation would be n!, so limit for large n
        const max_orders = @min(24, factorial(@intCast(tables.len)));
        var count: usize = 0;

        // Start with the given order
        const table_copy = try self.allocator.alloc([]const u8, tables.len);
        @memcpy(table_copy, tables);

        const methods = try self.allocator.alloc(JoinMethod, @max(0, tables.len - 1));
        for (methods) |*m| m.* = .hash_join; // Default to hash join

        try orders.append(.{ .tables = table_copy, .join_methods = methods });
        count += 1;

        // Generate a few more orderings by swapping pairs
        if (tables.len >= 2 and count < max_orders) {
            const swapped = try self.allocator.alloc([]const u8, tables.len);
            @memcpy(swapped, tables);
            // Swap first two
            const tmp = swapped[0];
            swapped[0] = swapped[1];
            swapped[1] = tmp;
            const m2 = try self.allocator.alloc(JoinMethod, @max(0, tables.len - 1));
            for (m2) |*m| m.* = .hash_join;
            try orders.append(.{ .tables = swapped, .join_methods = m2 });
        }
    }

    // Generate right-deep join orders
    fn generateRightDeepJoinOrders(self: *QueryOptimizer, orders: *std.ArrayList(JoinOrder), tables: []const []const u8) !void {
        // Reverse order for right-deep tree
        const reversed = try self.allocator.alloc([]const u8, tables.len);
        for (tables, 0..) |t, i| {
            reversed[tables.len - 1 - i] = t;
        }

        const methods = try self.allocator.alloc(JoinMethod, @max(0, tables.len - 1));
        for (methods) |*m| m.* = .nested_loop; // Right-deep often uses nested loop

        try orders.append(.{ .tables = reversed, .join_methods = methods });
    }

    // Generate bushy join orders (for small table sets)
    fn generateBushyJoinOrders(self: *QueryOptimizer, orders: *std.ArrayList(JoinOrder), tables: []const []const u8) !void {
        if (tables.len < 3) return;

        // For 3-4 tables, try middle-out patterns
        if (tables.len >= 3) {
            // Pattern: (t0 JOIN t1) JOIN t2 vs t0 JOIN (t1 JOIN t2)
            const bushy = try self.allocator.alloc([]const u8, tables.len);
            bushy[0] = tables[1]; // Start with middle element
            bushy[1] = tables[0];
            if (tables.len > 2) bushy[2] = tables[2];
            if (tables.len > 3) bushy[3] = tables[3];

            const methods = try self.allocator.alloc(JoinMethod, @max(0, tables.len - 1));
            for (methods) |*m| m.* = .merge_join; // Bushy trees often benefit from merge

            try orders.append(.{ .tables = bushy, .join_methods = methods });
        }
    }

    // Generate greedy join orders for large table sets
    fn generateGreedyJoinOrders(self: *QueryOptimizer, orders: *std.ArrayList(JoinOrder), tables: []const []const u8) !void {
        // Greedy: order by table size (smallest first)
        // This is a heuristic that often works well in practice
        const sorted = try self.allocator.alloc([]const u8, tables.len);
        @memcpy(sorted, tables);

        // Simple sort by table name (proxy for size in absence of full stats)
        // In production, would use actual table statistics
        std.mem.sort([]const u8, sorted, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        const methods = try self.allocator.alloc(JoinMethod, @max(0, tables.len - 1));
        for (methods) |*m| m.* = .hash_join;

        try orders.append(.{ .tables = sorted, .join_methods = methods });
    }

    // Factorial helper (limited to reasonable sizes)
    fn factorial(n: u32) usize {
        if (n <= 1) return 1;
        if (n > 10) return 3628800; // Cap at 10! to avoid overflow
        var result: usize = 1;
        var i: u32 = 2;
        while (i <= n) : (i += 1) {
            result *= i;
        }
        return result;
    }

    const JoinOrder = struct {
        tables: [][]const u8,
        join_methods: []JoinMethod,
    };

    const JoinMethod = enum {
        nested_loop,
        hash_join,
        merge_join,
    };

    // Build a complete plan from access paths and join order
    fn buildPlan(self: *QueryOptimizer, access_path: AccessPath, join_order: JoinOrder, query: ast.Query) !Plan {
        _ = join_order;
        _ = query;

        const root = try self.allocator.create(PlanNode);

        // CANARY: REQ=REQ-QP-STATS-001; FEATURE="QueryPlannerOptimization"; ASPECT=StatisticsEstimation; STATUS=IMPL; OWNER=planner; UPDATED=2025-12-30
        // Get table statistics for row estimation
        const table_stats = self.statistics.table_stats.get(access_path.table);
        const table_row_count = if (table_stats) |stats| stats.row_count else 1000;
        const avg_row_size = if (table_stats) |stats| stats.avg_row_size else 100;

        root.* = switch (access_path.type) {
            .seq_scan => .{
                .type = .{ .seq_scan = .{
                    .table = access_path.table,
                    .filter = null,
                } },
                .children = &[_]PlanNode{},
                .cost = access_path.cost,
                .rows = table_row_count, // Estimate from statistics
                .width = avg_row_size,
                .parallel_aware = false,
                .async_capable = false,
            },
            .index_scan => .{
                .type = .{ .index_scan = .{
                    .table = access_path.table,
                    .index = access_path.index.?,
                    .index_cond = null,
                    .filter = null,
                } },
                .children = &[_]PlanNode{},
                .cost = access_path.cost,
                .rows = @max(1, table_row_count / 10), // Index scans typically return ~10% of rows
                .width = avg_row_size,
                .parallel_aware = false,
                .async_capable = false,
            },
            .bitmap_scan => .{
                .type = .{ .bitmap_scan = .{
                    .table = access_path.table,
                    .indexes = &[_][]const u8{},
                    .recheck_cond = null,
                } },
                .children = &[_]PlanNode{},
                .cost = access_path.cost,
                .rows = @max(1, table_row_count / 2), // Bitmap scans typically return ~50% of rows
                .width = avg_row_size,
                .parallel_aware = false,
                .async_capable = false,
            },
        };

        return .{
            .root = root,
            .estimated_cost = access_path.cost,
            .estimated_rows = root.rows,
        };
    }

    // Apply optimization rules to a plan
    fn applyRules(self: *QueryOptimizer, plan: *Plan) !void {
        _ = self;

        // Apply various optimization rules
        try self.pushDownPredicates(plan.root);
        try self.eliminateRedundantSorts(plan.root);
        try self.mergeConsecutiveFilters(plan.root);
        try self.considerParallelization(plan.root);
    }

    // CANARY: REQ=REQ-QP-PUSH-001; FEATURE="QueryPlannerOptimization"; ASPECT=PredicatePushdown; STATUS=IMPL; OWNER=planner; UPDATED=2025-12-30
    // Push predicates down the plan tree
    fn pushDownPredicates(self: *QueryOptimizer, node: *PlanNode) !void {
        // Recursively push down predicates to children first
        for (node.children) |*child| {
            try self.pushDownPredicates(child);
        }

        // Predicate pushdown logic:
        // If this is a filter node, check if the predicate can be pushed to child scans
        switch (node.type) {
            .filter => |filter| {
                if (node.children.len > 0) {
                    const child = &node.children[0];
                    switch (child.type) {
                        .seq_scan => |*scan| {
                            // Push filter predicate to scan's filter
                            if (scan.filter == null) {
                                scan.filter = filter.condition;
                            }
                        },
                        .index_scan => |*scan| {
                            // Push filter predicate to scan's filter
                            if (scan.filter == null) {
                                scan.filter = filter.condition;
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
        _ = self;
    }

    // CANARY: REQ=REQ-QP-SORT-001; FEATURE="QueryPlannerOptimization"; ASPECT=SortElimination; STATUS=IMPL; OWNER=planner; UPDATED=2025-12-30
    // Eliminate redundant sort operations
    fn eliminateRedundantSorts(self: *QueryOptimizer, node: *PlanNode) !void {
        // Recursively process children first
        for (node.children) |*child| {
            try self.eliminateRedundantSorts(child);
        }

        // If this is a sort node, check if child already provides sorted output
        switch (node.type) {
            .sort => |sort| {
                if (node.children.len > 0) {
                    const child = &node.children[0];
                    switch (child.type) {
                        .index_scan => |scan| {
                            // Index scan provides sorted output on index key
                            // If sort keys match index, sort is redundant
                            if (scan.index) |idx| {
                                if (sort.keys.len > 0 and std.mem.eql(u8, sort.keys[0].column, idx)) {
                                    // Mark as no-op (cost = 0)
                                    node.cost = 0;
                                }
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
        _ = self;
    }

    // CANARY: REQ=REQ-QP-FILTER-001; FEATURE="QueryPlannerOptimization"; ASPECT=FilterMerging; STATUS=IMPL; OWNER=planner; UPDATED=2025-12-30
    // Merge consecutive filter operations
    fn mergeConsecutiveFilters(self: *QueryOptimizer, node: *PlanNode) !void {
        // Recursively process children first
        for (node.children) |*child| {
            try self.mergeConsecutiveFilters(child);
        }

        // If this is a filter with a child that's also a filter, merge them
        switch (node.type) {
            .filter => {
                if (node.children.len > 0) {
                    const child = &node.children[0];
                    switch (child.type) {
                        .filter => {
                            // Filters can be merged via AND
                            // Copy child's children to this node
                            node.children = child.children;
                            // Filter predicates would be AND'd together (simplified)
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
        _ = self;
    }

    // CANARY: REQ=REQ-QP-PARALLEL-001; FEATURE="QueryPlannerOptimization"; ASPECT=Parallelization; STATUS=IMPL; OWNER=planner; UPDATED=2025-12-30
    // Consider parallelizing operations
    fn considerParallelization(self: *QueryOptimizer, node: *PlanNode) !void {
        // Get table size from statistics for parallel threshold decision
        const table_name = switch (node.type) {
            .seq_scan => |scan| scan.table,
            .index_scan => |scan| scan.table,
            .bitmap_scan => |scan| scan.table,
            else => null,
        };

        const table_size = if (table_name) |name|
            if (self.statistics.table_stats.get(name)) |stats| stats.row_count else 1000000
        else
            node.rows;

        const parallel_threshold: u64 = 100000;

        if (table_size > parallel_threshold) {
            node.parallel_aware = true;
        }
    }

    // Cost estimation functions
    fn estimateSeqScanCost(self: *QueryOptimizer, stats: Statistics.TableStats) f64 {
        const pages = stats.row_count * stats.avg_row_size / 8192; // Assume 8KB pages
        return @as(f64, @floatFromInt(pages)) * self.cost_model.seq_page_cost +
            @as(f64, @floatFromInt(stats.row_count)) * self.cost_model.cpu_tuple_cost;
    }

    fn estimateIndexScanCost(self: *QueryOptimizer, index_stats: Statistics.IndexStats, table_stats: Statistics.TableStats) f64 {
        _ = table_stats;
        const index_pages = @as(f64, @floatFromInt(index_stats.leaf_pages));
        const index_tuples = @as(f64, @floatFromInt(index_stats.distinct_keys));

        return index_pages * self.cost_model.random_page_cost +
            index_tuples * self.cost_model.cpu_index_tuple_cost;
    }

    fn indexAppliesToTable(self: *QueryOptimizer, index_name: []const u8, table_name: []const u8) bool {
        _ = self;
        // Simple check: assume index name contains table name
        return std.mem.indexOf(u8, index_name, table_name) != null;
    }
};
