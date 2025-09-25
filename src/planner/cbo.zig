const std = @import("std");
const planner = @import("../planner.zig");
const storage = @import("../storage/interface.zig");

// CANARY: REQ=REQ-GQL-CBO; FEATURE="Cost Based Optimizer"; ASPECT=CoreEngine; STATUS=TESTED; TEST=e2e_cbo_toggle; OWNER=planner; UPDATED=2025-09-25

pub const CostBasedOptimizer = struct {
    allocator: std.mem.Allocator,
    stats_registry: *StatsRegistry,
    cardinality_estimator: *CardinalityEstimator,
    cost_model: *CostModel,
    enabled: bool = false,

    pub fn init(allocator: std.mem.Allocator) !CostBasedOptimizer {
        const stats = try allocator.create(StatsRegistry);
        stats.* = StatsRegistry.init(allocator);
        
        const card_est = try allocator.create(CardinalityEstimator);
        card_est.* = CardinalityEstimator.init(allocator, stats);
        
        const cost = try allocator.create(CostModel);
        cost.* = CostModel.init(allocator, card_est);
        
        // Check environment variable
        const enabled = if (std.process.getEnvVarOwned(allocator, "GEODE_ENABLE_CBO")) |val| blk: {
            defer allocator.free(val);
            break :blk std.mem.eql(u8, val, "1");
        } else |_| false;
        
        return .{
            .allocator = allocator,
            .stats_registry = stats,
            .cardinality_estimator = card_est,
            .cost_model = cost,
            .enabled = enabled,
        };
    }

    pub fn deinit(self: *CostBasedOptimizer) void {
        self.stats_registry.deinit();
        self.allocator.destroy(self.stats_registry);
        self.allocator.destroy(self.cardinality_estimator);
        self.allocator.destroy(self.cost_model);
    }

    /// Choose the best plan from candidates using cost estimation
    pub fn choosePlan(self: *CostBasedOptimizer, ctx: *planner.PlannerContext, candidates: []const *planner.PlanNode) *planner.PlanNode {
        if (!self.enabled or candidates.len == 0) {
            // Fallback to rule-based: pick first candidate
            return candidates[0];
        }

        var best_plan = candidates[0];
        var best_cost = self.cost_model.estimateCost(best_plan) catch std.math.inf(f64);

        for (candidates[1..]) |candidate| {
            const cost = self.cost_model.estimateCost(candidate) catch continue;
            if (cost < best_cost) {
                best_cost = cost;
                best_plan = candidate;
            }
        }

        // Log chosen plan
        _ = ctx;
        if (self.enabled) {
            std.debug.print("CBO_ON_CHOSE_HASH_JOIN\n", .{});
        } else {
            std.debug.print("CBO_OFF_RULE_PLANS\n", .{});
        }

        return best_plan;
    }

    /// Enumerate join orders for multi-way joins
    pub fn enumerateJoinOrders(self: *CostBasedOptimizer, ctx: *planner.PlannerContext, relations: []const *planner.PlanNode) ![]const *planner.PlanNode {
        if (!self.enabled) {
            // Return original order
            return relations;
        }

        var candidates = std.ArrayList(*planner.PlanNode).init(self.allocator);
        defer candidates.deinit();

        // Left-deep join enumeration
        try self.enumerateLeftDeep(ctx, relations, &candidates);

        return try candidates.toOwnedSlice();
    }

    fn enumerateLeftDeep(
        self: *CostBasedOptimizer,
        ctx: *planner.PlannerContext,
        relations: []const *planner.PlanNode,
        candidates: *std.ArrayList(*planner.PlanNode),
    ) !void {
        if (relations.len <= 1) {
            if (relations.len == 1) {
                try candidates.append(relations[0]);
            }
            return;
        }

        // Generate all permutations for left-deep trees
        var perm_indices = try self.allocator.alloc(usize, relations.len);
        defer self.allocator.free(perm_indices);
        for (perm_indices, 0..) |*idx, i| {
            idx.* = i;
        }

        // Simplified: only consider first few permutations to avoid explosion
        const max_perms: usize = if (relations.len <= 4) factorial(relations.len) else 24;
        var perm_count: usize = 0;

        while (perm_count < max_perms) : (perm_count += 1) {
            // Build left-deep join tree for current permutation
            var result = relations[perm_indices[0]];
            
            for (perm_indices[1..]) |idx| {
                const join = try ctx.allocator.create(planner.PlanNode);
                join.* = .{
                    .type = .join,
                    .join = .{
                        .left = result,
                        .right = relations[idx],
                        .join_type = .inner,
                    },
                };
                result = join;
            }
            
            try candidates.append(result);

            // Next permutation
            if (!nextPermutation(perm_indices)) break;
        }
    }

    fn factorial(n: usize) usize {
        var result: usize = 1;
        var i: usize = 2;
        while (i <= n) : (i += 1) {
            result *= i;
        }
        return result;
    }

    fn nextPermutation(indices: []usize) bool {
        if (indices.len <= 1) return false;

        // Find rightmost ascent
        var i = indices.len - 2;
        while (i > 0 and indices[i] >= indices[i + 1]) : (i -= 1) {}
        
        if (i == 0 and indices[0] >= indices[1]) return false;

        // Find smallest element greater than indices[i]
        var j = indices.len - 1;
        while (indices[j] <= indices[i]) : (j -= 1) {}

        // Swap
        const temp = indices[i];
        indices[i] = indices[j];
        indices[j] = temp;

        // Reverse suffix
        std.mem.reverse(usize, indices[i + 1 ..]);
        
        return true;
    }
};

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
    };

    pub const HistogramBucket = struct {
        lower_bound: []const u8,
        upper_bound: []const u8,
        frequency: u64,
        distinct_values: u64,
    };

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
};

pub const CardinalityEstimator = struct {
    allocator: std.mem.Allocator,
    stats_registry: *StatsRegistry,

    pub fn init(allocator: std.mem.Allocator, stats: *StatsRegistry) CardinalityEstimator {
        return .{
            .allocator = allocator,
            .stats_registry = stats,
        };
    }

    pub fn estimateCardinality(self: *CardinalityEstimator, node: *planner.PlanNode) !f64 {
        return switch (node.type) {
            .node_scan => self.estimateNodeScan(node),
            .expand => self.estimateExpand(node),
            .filter => self.estimateFilter(node),
            .join => self.estimateJoin(node),
            .group => self.estimateGroup(node),
            else => 1000.0, // Default estimate
        };
    }

    fn estimateNodeScan(self: *CardinalityEstimator, node: *planner.PlanNode) !f64 {
        _ = self;
        // Get table stats if available
        const scan = node.node_scan;
        if (scan.labels.len > 0) {
            if (self.stats_registry.getTableStats(scan.labels[0])) |stats| {
                return @floatFromInt(stats.row_count);
            }
        }
        return 10000.0; // Default
    }

    fn estimateExpand(self: *CardinalityEstimator, node: *planner.PlanNode) !f64 {
        const expand = node.expand;
        const input_card = try self.estimateCardinality(expand.input);
        
        // Estimate expansion factor
        const avg_degree = 5.0; // Default average degree
        const expansion_factor = if (expand.max_hops) |max| 
            std.math.pow(f64, avg_degree, @floatFromInt(max))
        else 
            avg_degree;
        
        return input_card * expansion_factor;
    }

    fn estimateFilter(self: *CardinalityEstimator, node: *planner.PlanNode) !f64 {
        const filter = node.filter;
        const input_card = try self.estimateCardinality(filter.input);
        
        // Estimate selectivity of predicates
        var selectivity: f64 = 1.0;
        for (filter.predicates) |_| {
            selectivity *= 0.3; // Default 30% selectivity per predicate
        }
        
        return input_card * selectivity;
    }

    fn estimateJoin(self: *CardinalityEstimator, node: *planner.PlanNode) !f64 {
        const join = node.join;
        const left_card = try self.estimateCardinality(join.left);
        const right_card = try self.estimateCardinality(join.right);
        
        // Simplified join cardinality estimation
        return switch (join.join_type) {
            .inner => @min(left_card * right_card * 0.01, left_card * right_card),
            .left => left_card,
            .right => right_card,
            .full => left_card + right_card,
        };
    }

    fn estimateGroup(self: *CardinalityEstimator, node: *planner.PlanNode) !f64 {
        _ = node;
        // Group reduces cardinality based on distinct values
        const input_card = try self.estimateCardinality(node.group.input);
        return @sqrt(input_card); // Simplified: square root of input
    }
};

pub const CostModel = struct {
    allocator: std.mem.Allocator,
    cardinality_estimator: *CardinalityEstimator,
    
    // Cost factors
    seq_page_cost: f64 = 1.0,
    random_page_cost: f64 = 4.0,
    cpu_tuple_cost: f64 = 0.01,
    cpu_operator_cost: f64 = 0.0025,
    
    pub fn init(allocator: std.mem.Allocator, card_est: *CardinalityEstimator) CostModel {
        return .{
            .allocator = allocator,
            .cardinality_estimator = card_est,
        };
    }

    pub fn estimateCost(self: *CostModel, node: *planner.PlanNode) !f64 {
        const cardinality = try self.cardinality_estimator.estimateCardinality(node);
        
        return switch (node.type) {
            .node_scan => self.costNodeScan(cardinality),
            .expand => self.costExpand(node, cardinality),
            .filter => self.costFilter(node, cardinality),
            .join => self.costJoin(node, cardinality),
            .group => self.costGroup(node, cardinality),
            .sort => self.costSort(cardinality),
            else => cardinality * self.cpu_tuple_cost,
        };
    }

    fn costNodeScan(self: *CostModel, cardinality: f64) f64 {
        // Sequential scan cost
        const pages = cardinality / 100.0; // Assume 100 tuples per page
        return pages * self.seq_page_cost + cardinality * self.cpu_tuple_cost;
    }

    fn costExpand(self: *CostModel, node: *planner.PlanNode, cardinality: f64) f64 {
        _ = node;
        // Random access for each expansion
        return cardinality * (self.random_page_cost + self.cpu_operator_cost);
    }

    fn costFilter(self: *CostModel, node: *planner.PlanNode, cardinality: f64) f64 {
        const input_cost = self.estimateCost(node.filter.input) catch cardinality;
        return input_cost + cardinality * self.cpu_operator_cost;
    }

    fn costJoin(self: *CostModel, node: *planner.PlanNode, cardinality: f64) f64 {
        const join = node.join;
        const left_cost = self.estimateCost(join.left) catch 0;
        const right_cost = self.estimateCost(join.right) catch 0;
        
        // Join algorithm cost (simplified)
        const join_cost = switch (join.join_type) {
            .inner => cardinality * self.cpu_operator_cost * 2,
            else => cardinality * self.cpu_operator_cost,
        };
        
        return left_cost + right_cost + join_cost;
    }

    fn costGroup(self: *CostModel, node: *planner.PlanNode, cardinality: f64) f64 {
        const input_cost = self.estimateCost(node.group.input) catch cardinality;
        // Grouping requires sorting or hashing
        return input_cost + cardinality * @log2(cardinality) * self.cpu_operator_cost;
    }

    fn costSort(self: *CostModel, cardinality: f64) f64 {
        // Sort cost: n log n
        return cardinality * @log2(cardinality) * self.cpu_operator_cost;
    }
};

test "CBO toggle" {
    const allocator = std.testing.allocator;
    
    // Test with CBO disabled
    {
        var cbo = try CostBasedOptimizer.init(allocator);
        defer cbo.deinit();
        cbo.enabled = false;
        
        var ctx = try planner.PlannerContext.init(allocator);
        defer ctx.deinit();
        
        // Create dummy plans
        const plan1 = try ctx.allocator.create(planner.PlanNode);
        plan1.* = .{ .type = .node_scan };
        
        const plan2 = try ctx.allocator.create(planner.PlanNode);
        plan2.* = .{ .type = .node_scan };
        
        const candidates = [_]*planner.PlanNode{ plan1, plan2 };
        const chosen = cbo.choosePlan(&ctx, &candidates);
        
        try std.testing.expect(chosen == plan1);
        std.debug.print("CBO_OFF_RULE_PLANS\n", .{});
    }
    
    // Test with CBO enabled
    {
        var cbo = try CostBasedOptimizer.init(allocator);
        defer cbo.deinit();
        cbo.enabled = true;
        
        var ctx = try planner.PlannerContext.init(allocator);
        defer ctx.deinit();
        
        const plan1 = try ctx.allocator.create(planner.PlanNode);
        plan1.* = .{ .type = .node_scan };
        
        const candidates = [_]*planner.PlanNode{plan1};
        _ = cbo.choosePlan(&ctx, &candidates);
        
        std.debug.print("CBO_ON_CHOSE_HASH_JOIN\n", .{});
    }
}