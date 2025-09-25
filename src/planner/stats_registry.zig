const std = @import("std");
const enumerator = @import("enumerator.zig");
const cost_model = @import("cost_model.zig");

// Lightweight statistics registry mapping plan structural signatures (same hashing
// scheme as enumerator.PlanEnumerator.signatureOf) to estimated row counts.
// This enables deterministic cardinality injection without modifying LogicalPlan shape.
// Future slices can extend mapping granularity to per-scan identifiers once LogicalPlan
// carries relation metadata. For now, signatures differentiate by operator tree.
//
// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanStatisticsRegistry; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_024_PlanStatisticsRegistry; OWNER=planner; UPDATED=2025-09-24
pub const StatsRegistry = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMap(u64, u64), // signature -> estimated rows

    pub fn init(alloc: std.mem.Allocator) StatsRegistry {
        return .{ .allocator = alloc, .map = std.AutoHashMap(u64, u64).init(alloc) };
    }
    pub fn deinit(self: *StatsRegistry) void {
        self.map.deinit();
    }
    pub fn put(self: *StatsRegistry, sig: u64, rows: u64) !void {
        try self.map.put(sig, rows);
    }
    pub fn get(self: *StatsRegistry, sig: u64) ?u64 {
        return self.map.get(sig);
    }
};

fn signatureOf(node: enumerator.LogicalPlan) u64 {
    var h: u64 = @intFromEnum(node.op) ^ (@as(u64, node.children.len) << 8);
    for (node.children, 0..) |c, i| {
        h ^= (signatureOf(c) +% (@as(u64, i) << 16)) *% 0x9E3779B185EBCA87;
    }
    return h;
}

const WalkStatResult = struct { cost: f64, rows: f64, joins: usize };

fn walkWithStats(node: enumerator.LogicalPlan, f: cost_model.CostFactors, sr: *StatsRegistry, depth: usize) WalkStatResult {
    // Depth can mildly inflate base to discourage overly deep trees in absence of joins.
    const depth_factor: f64 = 1.0 + (@as(f64, @floatFromInt(depth)) * 0.01);
    const base: f64 = (switch (node.op) {
        .scan => f.scan_base,
        .filter => f.filter_base,
        .project => f.project_base,
        .join => f.join_base,
        .aggregate => f.aggregate_base,
        .sort => f.sort_base,
        .limit => f.limit_base,
    }) * depth_factor;
    const sig_self = signatureOf(node);
    if (node.children.len == 0) {
        const row_est_leaf: f64 = if (sr.get(sig_self)) |r| @floatFromInt(r) else 1.0;
        return .{ .cost = base + (row_est_leaf / 1000.0) * f.per_k_rows, .rows = row_est_leaf, .joins = if (node.op == .join) 1 else 0 };
    }
    var total_cost: f64 = base;
    var row_est: f64 = 1.0;
    var joins: usize = if (node.op == .join) 1 else 0;
    for (node.children) |child| {
        const r = walkWithStats(child, f, sr, depth + 1);
        total_cost += r.cost;
        // With statistics we multiply by (1 + child_rows/child_rows_scale) for simplistic growth
        row_est *= (1.0 + r.rows * 0.001);
        joins += r.joins;
    }
    // If stats registry has explicit cardinality for this node signature, override row_est with that value
    if (sr.get(sig_self)) |rows_override| {
        row_est = @floatFromInt(rows_override);
    }
    total_cost += (row_est / 1000.0) * f.per_k_rows;
    if (joins > 1) {
        total_cost *= std.math.pow(f64, f.join_depth_penalty, @floatFromInt(joins - 1));
    }
    return .{ .cost = total_cost, .rows = row_est, .joins = joins };
}

pub fn estimatePlanCostWithStats(root: enumerator.LogicalPlan, factors: cost_model.CostFactors, sr: *StatsRegistry) f64 {
    return walkWithStats(root, factors, sr, 0).cost;
}

test "TestCANARY_REQ_GQL_024_PlanStatisticsRegistry" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var reg = StatsRegistry.init(gpa.allocator());
    defer reg.deinit();
    // Build two alternative trees:
    // A: join(scan, scan)
    const scan_leaf = enumerator.LogicalPlan{ .op = .scan, .children = &.{} };
    var join_children = [_]enumerator.LogicalPlan{ scan_leaf, scan_leaf }; // duplicate signature intentionally
    const join_plan = enumerator.LogicalPlan{ .op = .join, .children = join_children[0..] };
    // B: project(scan)
    var proj_children = [_]enumerator.LogicalPlan{scan_leaf};
    const project_plan = enumerator.LogicalPlan{ .op = .project, .children = proj_children[0..] };
    const factors: cost_model.CostFactors = .{};
    // Without stats, cost model likely prefers project over join (join higher base).
    const base_join = cost_model.estimatePlanCost(join_plan, factors);
    const base_proj = cost_model.estimatePlanCost(project_plan, factors);
    try std.testing.expect(base_join > base_proj);
    // Inject stats so join children have extremely low rows (simulate selective joins) while project scan huge.
    const scan_sig = signatureOf(scan_leaf);
    try reg.put(scan_sig, 1); // leaves tiny
    const project_sig = signatureOf(project_plan);
    try reg.put(project_sig, 1_000_000); // project result large (penalize)
    const cost_join_stats = estimatePlanCostWithStats(join_plan, factors, &reg);
    const cost_proj_stats = estimatePlanCostWithStats(project_plan, factors, &reg);
    // Expect join now cheaper than project with stats influence
    try std.testing.expect(cost_join_stats < cost_proj_stats);
}
