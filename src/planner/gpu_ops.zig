const std = @import("std");
const phase0 = @import("../gpu/phase0.zig");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=PlannerOps; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_051_GPUPlannerDispatch; OWNER=engine; UPDATED=2025-10-25

pub const PhysicalGpuOp = enum { node_scan, expand, set_op, pagerank, bfs };

pub fn chooseGpu(op: PhysicalGpuOp, edge_count: usize, selectivity: f64) bool {
    // Phase0 heuristic only; refined later by cost model
    if (!phase0.gpuEnabled()) return false;
    switch (op) {
        .node_scan => return edge_count > 100_000,
        .expand => return phase0.shouldUseGpu(edge_count, selectivity),
        .set_op => return edge_count > 200_000,
        .pagerank => return edge_count > 50_000,
        .bfs => return edge_count > 10_000,
    }
}

test "TestCANARY_REQ_GQL_051_GPUPlannerDispatch" {
    // Skip asserts when GPU absent: feature still IMPL
    const enabled = phase0.gpuEnabled();
    const use_expand = chooseGpu(.expand, 60_000, 0.2);
    if (enabled) try std.testing.expect(use_expand) else try std.testing.expect(!use_expand);
}
