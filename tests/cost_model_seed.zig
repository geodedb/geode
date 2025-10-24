const std = @import("std");
const seed = @import("../src/planner/cost_seed.zig");

// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=EstimatorPrimitives; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_CostModelSeedBasicEstimates; OWNER=planner; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_075_CostModelSeedBasicEstimates" {
    const cfg = seed.EstimatorConfig{};
    const scan = seed.estimate(.{ .kind = .Scan }, &[_]seed.CardinalityEstimate{}, cfg);
    const expd = seed.estimate(.{ .kind = .Expand }, &[_]seed.CardinalityEstimate{scan}, cfg);
    const filt = seed.estimate(.{ .kind = .Filter, .selectivity = 0.3 }, &[_]seed.CardinalityEstimate{expd}, cfg);
    // Monotonic reductions: filter should not increase rows.
    try std.testing.expect(filt.rows <= expd.rows);
    // Expand should increase or equal relative to scan when degree > 1.
    try std.testing.expect(expd.rows >= scan.rows);
    // Cost sanity: total cost positive
    const scan_cost = seed.cost(.{ .kind = .Scan }, scan, cfg).total();
    try std.testing.expect(scan_cost > 0);
}
