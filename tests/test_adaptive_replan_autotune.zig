const std = @import("std");
const bench = @import("../src/benchmarks/adaptive_replan_autotune_variance.zig");

// Test ensures the adaptive replan autotune variance envelope converges and passes thresholds.
// CANARY: REQ=REQ-GQL-021; FEATURE="Adaptive Replan Autotune"; ASPECT=AdaptiveReplanAutotuneConvergence; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_AdaptiveReplanAutotuneConvergence; OWNER=planner; UPDATED=2025-09-22
test "TestCANARY_REQ_GQL_021_AdaptiveReplanAutotuneConvergence" {
    try bench.benchmarkAdaptiveReplanAutotuneVarianceEnvelope();
}
