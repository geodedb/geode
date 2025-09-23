const std = @import("std");
const enumerator = @import("enumerator.zig");

// Simple heuristic cost model factoring cardinality & selectivity like signals
// derived from query structure (number of leaves, join depth) and operator weights.
// This augments the naive structural weighting inside the enumerator. We recompute
// refined costs post-enumeration to choose a better candidate without modifying the
// enumerator's internal recursion (keeps enumeration stable while allowing evolution
// of cost heuristics as a separate slice).
//
// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanCostModelFactors; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_PlanCostModelFactors; BENCH=BenchmarkCANARY_REQ_GQL_024_PlanCostModelVarianceEnvelope; OWNER=planner; UPDATED=2025-09-23
// After tests & bench run this promotes automatically.

pub const CostFactors = struct {
    scan_base: f64 = 1.0,
    filter_base: f64 = 0.5,
    project_base: f64 = 0.2,
    join_base: f64 = 4.0,
    aggregate_base: f64 = 2.5,
    sort_base: f64 = 3.5,
    limit_base: f64 = 0.1,
    // Row production penalty multiplier per estimated 1k rows (keeps numbers bounded)
    per_k_rows: f64 = 0.05,
    // Join depth exponential dampener (reduces preference for very deep left-deep trees)
    join_depth_penalty: f64 = 1.15,
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
