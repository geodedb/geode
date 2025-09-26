const std = @import("std");
const enumerator = @import("enumerator.zig");
const cost_model = @import("cost_model.zig");

// Candidate plan rescoring integration: apply refined cost model (with optional calibration)
// to a pre-enumerated candidate list produced via enumerator.PlanEnumerator. Returns
// the best candidate index under refined costing and whether this differs from the
// structural (enumerator) choice. Does NOT mutate the original array so callers may
// compare structural vs refined costs side-by-side. A follow-up slice may persist
// refined costs back into a plan cache.
//
// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanCandidateRescoringIntegration; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_PlanCandidateRescoringIntegration; OWNER=planner; UPDATED=2025-09-26
pub const RescoreResult = struct {
    structural_best_index: ?usize,
    refined_best_index: ?usize,
    structural_best_cost: f64 = std.math.inf(f64),
    refined_best_cost: f64 = std.math.inf(f64),
    improved: bool = false, // true if refined selects different index than structural
};

pub fn rescoreCandidates(
    candidates: []const enumerator.CandidatePlan,
    factors: cost_model.CostFactors,
    maybe_cal: ?*const @import("cost_calibration.zig").Calibration,
) RescoreResult {
    if (candidates.len == 0) return .{ .structural_best_index = null, .refined_best_index = null };
    var structural_best_index: usize = 0;
    var structural_best_cost = candidates[0].cost;
    // Identify structural best (enumerator heuristic) first.
    for (candidates[1..], 1..) |cp, i| {
        if (cp.cost < structural_best_cost) {
            structural_best_cost = cp.cost;
            structural_best_index = i;
        }
    }
    // Apply refined cost model.
    var refined_best_index: usize = 0;
    var refined_best_cost: f64 = std.math.inf(f64);
    for (candidates, 0..) |cp, i| {
        const rcost = cost_model.estimateWithCalibration(cp.plan, factors, maybe_cal);
        if (rcost < refined_best_cost) {
            refined_best_cost = rcost;
            refined_best_index = i;
        }
    }
    return .{
        .structural_best_index = structural_best_index,
        .refined_best_index = refined_best_index,
        .structural_best_cost = structural_best_cost,
        .refined_best_cost = refined_best_cost,
        .improved = refined_best_index != structural_best_index,
    };
}

test "TestCANARY_REQ_GQL_024_PlanCandidateRescoringIntegration" {
    // Construct two logical plans manually so we avoid depending on enumerator recursion:
    // Plan 0: simple scan
    const scan_leaf = enumerator.LogicalPlan{ .op = .scan, .children = &.{} };
    // Plan 1: project over scan (structural heuristic prefers project over scan because
    // enumerator weight( project=3 + 0.5*scan(10) = 8 ) < scan(10 )
    var project_children = [_]enumerator.LogicalPlan{scan_leaf};
    const project_plan = enumerator.LogicalPlan{ .op = .project, .children = project_children[0..] };

    var candidates = [_]enumerator.CandidatePlan{
        .{ .cost = 10, .plan = scan_leaf, .signature = 0xA },
        .{ .cost = 8, .plan = project_plan, .signature = 0xB },
    };
    const factors: cost_model.CostFactors = .{};
    // No calibration for this test (baseline factors).
    const res = rescoreCandidates(candidates[0..], factors, null);
    try std.testing.expect(res.structural_best_index.? == 1); // project chosen structurally
    try std.testing.expect(res.refined_best_index.? == 0); // scan chosen by refined model
    try std.testing.expect(res.improved); // different choice
    try std.testing.expect(res.refined_best_cost < res.structural_best_cost);
}
