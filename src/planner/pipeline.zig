const std = @import("std");

// Zig 0.16 compat helper for the variance test below
fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.REALTIME, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

// NOTE: Use root planner module via relative import. This file is only compiled
// through a module whose root is src/planner, so the parent reference is stable.
// Tests that compile this file as its own root must import it through the same
// module tree to avoid Zig's "import of file outside module path" error.
const planner_root = @import("../planner.zig");
const structural_key = @import("structural_key.zig");
const enumerator_mod = @import("enumerator.zig");
const cost_model = @import("cost_model.zig");

// SONNY-6511: the synthetic "pipeline" (runPipeline, planQueryWithPipeline,
// the PathCache hooks, planQueryRealTimed) and the PathCache, PhaseTimer,
// AdaptiveReplan, rewrite-hook and WCOJ modules it drove were deleted: none
// compiled on Zig 0.16 and no executable or running test reached them. What
// remains is the cost-based plan selection that
// tests/canary_planner_pipeline_selection.zig runs, and the structural-key tests.

// Integrate cost-based enumerator selection into pipeline: build a synthetic logical plan tree
// from the query structure (currently uses number of return items + pattern chains) and invoke
// PlanEnumerator.selectBestUnmanaged. Returns the best candidate plus enumeration stats.
// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanSelectionPipelineAdoption; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_PlanSelectionPipelineAdoption; OWNER=planner; UPDATED=2025-09-22
pub const BestPlanResult = struct {
    best: ?enumerator_mod.CandidatePlan,
    total_candidates: usize,
    pruned: usize,
    /// SONNY-2394: owns the synthetic logical tree and the enumerated
    /// candidates that `best.plan` points into. Both used to be allocated
    /// straight from the caller's allocator and never freed (a leak on every
    /// call); freeing them before returning would leave `best.plan.children`
    /// dangling, so the result owns them. Call deinit() when done.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *BestPlanResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn buildLogicalTree(q: planner_root.ast.Query, alloc: std.mem.Allocator) !enumerator_mod.LogicalPlan {
    // Derive leaf count: at least 1; use number of return items or chains * hops length fallback
    var leaves: usize = q.ret.items.len;
    if (leaves == 0) leaves = q.match.chains.len;
    if (leaves == 0) leaves = 1;
    // Allocate an array of scan leaves
    const leaf_nodes = try alloc.alloc(enumerator_mod.LogicalPlan, leaves);
    for (leaf_nodes) |*ln| ln.* = .{ .op = .scan, .children = &.{} };
    // Build a simple left-deep join tree
    var current: enumerator_mod.LogicalPlan = leaf_nodes[0];
    var i: usize = 1;
    while (i < leaves) : (i += 1) {
        var children_buf = try alloc.alloc(enumerator_mod.LogicalPlan, 2);
        children_buf[0] = current;
        children_buf[1] = leaf_nodes[i];
        current = .{ .op = .join, .children = children_buf };
    }
    return current;
}

pub fn planQuerySelectBest(
    allocator: std.mem.Allocator,
    q: planner_root.ast.Query,
    enum_cfg: enumerator_mod.EnumeratorConfig,
) !BestPlanResult {
    // Ensure core legality (ORDER/LIMIT etc.) still validated
    _ = try planner_root.planQuery(allocator, q, .{});
    // The tree, the enumerator's swapped-join children and the candidate list
    // all live in one arena owned by the returned result (see BestPlanResult).
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const tree = try buildLogicalTree(q, a);
    // Enumerate all candidates (unmanaged) then apply refined cost model for final selection
    var pe = enumerator_mod.PlanEnumerator.init(a, enum_cfg);
    var buf = std.ArrayList(enumerator_mod.CandidatePlan).empty;
    try pe.enumerateUnmanaged(tree, a, &buf);
    if (buf.items.len == 0) return .{ .best = null, .total_candidates = 0, .pruned = pe.stats.pruned, .arena = arena };
    // Apply refined cost model across candidates
    const factors: cost_model.CostFactors = .{};
    // Perform a synthetic calibration pass to adjust relative operator weights.
    var calibration = @import("cost_calibration.zig").Calibration.init(allocator);
    @import("cost_calibration.zig").simulateSamples(&calibration) catch {};
    defer calibration.deinit();
    var best_cp: ?enumerator_mod.CandidatePlan = null;
    var best_cost: f64 = std.math.inf(f64);
    for (buf.items) |cp| {
        const refined = cost_model.estimateWithCalibration(cp.plan, factors, &calibration);
        if (refined < best_cost) {
            best_cost = refined;
            best_cp = cp; // keep original candidate (struct copy)
        }
    }
    // Overwrite selected candidate.cost with refined cost for visibility
    if (best_cp) |*sel| sel.cost = best_cost;
    return .{ .best = best_cp, .total_candidates = buf.items.len, .pruned = pe.stats.pruned, .arena = arena };
}

// Expose a canonical minimal empty query for tests/benchmarks so they don't need to import planner_root directly.
pub fn defaultEmptyQuery() planner_root.ast.Query {
    return .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = null, .having = null, .ret = .{ .items = &.{}, .distinct = false }, .order_by = null, .limit = null, .offset = null };
}

// Selection adoption & variance envelope tests moved to external file
// tests/canary_planner_pipeline_selection.zig to avoid module path conflicts.
// (See CANARY aspects PlanSelectionPipelineAdoption / PlanSelectionPipelineVarianceEnvelope.)

// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanCostModelCalibrationRanking; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_PlanCostModelCalibrationRanking; OWNER=planner; UPDATED=2025-09-22
test "TestCANARY_REQ_GQL_024_PlanCostModelCalibrationRanking" {
    const factors: cost_model.CostFactors = .{};
    // Lightweight synthetic plans built inline (no enumeration):
    const scan_leaf = enumerator_mod.LogicalPlan{ .op = .scan, .children = &.{} };
    const project = enumerator_mod.LogicalPlan{ .op = .project, .children = &.{scan_leaf} };
    const scan2 = enumerator_mod.LogicalPlan{ .op = .scan, .children = &.{} };
    const join_node = enumerator_mod.LogicalPlan{ .op = .join, .children = &.{ scan_leaf, scan2 } };
    const sort_node = enumerator_mod.LogicalPlan{ .op = .sort, .children = &.{join_node} };
    const baseA = cost_model.estimatePlanCost(project, factors);
    const baseB = cost_model.estimatePlanCost(sort_node, factors);
    try std.testing.expect(baseB > baseA);
    var cal = @import("cost_calibration.zig").Calibration.init(std.testing.allocator);
    defer cal.deinit();
    try @import("cost_calibration.zig").simulateSamples(&cal);
    const adjA = cost_model.estimateWithCalibration(project, factors, &cal);
    const adjB = cost_model.estimateWithCalibration(sort_node, factors, &cal);
    const delta_base = baseB - baseA;
    const delta_adj = adjB - adjA;
    try std.testing.expect(delta_adj >= delta_base);
}

test "TestCANARY_REQ_GQL_021_PathCacheStructuralKeyEquivalence" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    // Two queries differing in property literal values but same property key counts
    var q1: planner_root.ast.Query = .{
        .optional_match = false,
        .match = .{ .chains = &.{} },
        .where_clause = null,
        .with_clause = null,
        .group_by = null,
        .having = null,
        .ret = .{ .items = &.{}, .distinct = false },
        .order_by = null,
        .limit = null,
        .offset = null,
    };
    var q2 = q1;
    // Build hop with properties on left node (ignored values)
    var prop_val1 = planner_root.ast.Expr{ .Int = 1 };
    var prop_val2 = planner_root.ast.Expr{ .Int = 999 };
    const prop1 = planner_root.ast.Property{ .key = "p", .value = &prop_val1 };
    const prop2 = planner_root.ast.Property{ .key = "p", .value = &prop_val2 };
    const left1 = planner_root.ast.NodePattern{ .name = "n", .labels = &.{"L"}, .props = &.{prop1} };
    const left2 = planner_root.ast.NodePattern{ .name = "n2", .labels = &.{"L"}, .props = &.{prop2} };
    const right = planner_root.ast.NodePattern{ .name = null, .labels = &.{}, .props = null };
    const rel = planner_root.ast.RelPattern{ .name = null, .types = &.{}, .props = null, .dir = .undirected, .min_len = 1, .max_len = 3 };
    const hop1 = planner_root.ast.Hop{ .left = left1, .rel = rel, .right = right };
    const hop2 = planner_root.ast.Hop{ .left = left2, .rel = rel, .right = right };
    const chain1 = planner_root.ast.Chain{ .name = null, .hops = &.{hop1} };
    const chain2 = planner_root.ast.Chain{ .name = null, .hops = &.{hop2} };
    q1.match = .{ .chains = &.{chain1} };
    q2.match = .{ .chains = &.{chain2} };
    const key1 = try structural_key.deriveStructuralKey(gpa.allocator(), q1);
    defer gpa.allocator().free(key1);
    const key2 = try structural_key.deriveStructuralKey(gpa.allocator(), q2);
    defer gpa.allocator().free(key2);
    try std.testing.expect(std.mem.eql(u8, key1, key2));
}

test "TestCANARY_REQ_GQL_021_PathCacheStructuralKeyDifferentiation" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    // Two queries differing only in property KEY sets should yield different structural keys.
    var q1: planner_root.ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = null, .having = null, .ret = .{ .items = &.{}, .distinct = false }, .order_by = null, .limit = null, .offset = null };
    var q2 = q1;
    var valA = planner_root.ast.Expr{ .Int = 1 };
    var valB = planner_root.ast.Expr{ .Int = 2 };
    const pa = planner_root.ast.Property{ .key = "a", .value = &valA };
    const pb = planner_root.ast.Property{ .key = "b", .value = &valB };
    const left1 = planner_root.ast.NodePattern{ .name = "n", .labels = &.{"L"}, .props = &.{pa} };
    const left2 = planner_root.ast.NodePattern{ .name = "n", .labels = &.{"L"}, .props = &.{ pa, pb } };
    const right = planner_root.ast.NodePattern{ .name = null, .labels = &.{}, .props = null };
    const rel = planner_root.ast.RelPattern{ .name = null, .types = &.{}, .props = null, .dir = .right };
    const hop1 = planner_root.ast.Hop{ .left = left1, .rel = rel, .right = right };
    const hop2 = planner_root.ast.Hop{ .left = left2, .rel = rel, .right = right };
    const chain1 = planner_root.ast.Chain{ .name = null, .hops = &.{hop1} };
    const chain2 = planner_root.ast.Chain{ .name = null, .hops = &.{hop2} };
    q1.match = .{ .chains = &.{chain1} };
    q2.match = .{ .chains = &.{chain2} };
    const k1 = try structural_key.deriveStructuralKey(gpa.allocator(), q1);
    defer gpa.allocator().free(k1);
    const k2 = try structural_key.deriveStructuralKey(gpa.allocator(), q2);
    defer gpa.allocator().free(k2);
    try std.testing.expect(!std.mem.eql(u8, k1, k2));
}

test "TestCANARY_REQ_GQL_021_PathCacheStructuralKeyValueShapeDifferentiation" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    // Two queries identical except value type (Int vs String) for same property key
    var q1: planner_root.ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = null, .having = null, .ret = .{ .items = &.{}, .distinct = false }, .order_by = null, .limit = null, .offset = null };
    var q2 = q1;
    var valInt = planner_root.ast.Expr{ .Int = 7 };
    var valStr = planner_root.ast.Expr{ .String = "7" };
    const pInt = planner_root.ast.Property{ .key = "p", .value = &valInt };
    const pStr = planner_root.ast.Property{ .key = "p", .value = &valStr };
    const left1 = planner_root.ast.NodePattern{ .name = "n", .labels = &.{"L"}, .props = &.{pInt} };
    const left2 = planner_root.ast.NodePattern{ .name = "n", .labels = &.{"L"}, .props = &.{pStr} };
    const right = planner_root.ast.NodePattern{ .name = null, .labels = &.{}, .props = null };
    const rel = planner_root.ast.RelPattern{ .name = null, .types = &.{}, .props = null, .dir = .right };
    const hop1 = planner_root.ast.Hop{ .left = left1, .rel = rel, .right = right };
    const hop2 = planner_root.ast.Hop{ .left = left2, .rel = rel, .right = right };
    const chain1 = planner_root.ast.Chain{ .name = null, .hops = &.{hop1} };
    const chain2 = planner_root.ast.Chain{ .name = null, .hops = &.{hop2} };
    q1.match = .{ .chains = &.{chain1} };
    q2.match = .{ .chains = &.{chain2} };
    const k1 = try structural_key.deriveStructuralKey(gpa.allocator(), q1);
    defer gpa.allocator().free(k1);
    const k2 = try structural_key.deriveStructuralKey(gpa.allocator(), q2);
    defer gpa.allocator().free(k2);
    try std.testing.expect(!std.mem.eql(u8, k1, k2));
}

// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheStructuralKeySelectivityEnrichment; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_PathCacheStructuralKeySelectivityClassEncoding; OWNER=planner; UPDATED=2025-09-21
test "TestCANARY_REQ_GQL_021_PathCacheStructuralKeySelectivityClassEncoding" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    // Build three queries with 0,1,2,4 properties to exercise Z,L,M,H classes on left node.
    const base: planner_root.ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = null, .having = null, .ret = .{ .items = &.{}, .distinct = false }, .order_by = null, .limit = null, .offset = null };
    // Helper to make prop expr
    var v1 = planner_root.ast.Expr{ .Int = 1 };
    var v2 = planner_root.ast.Expr{ .Int = 2 };
    var v3 = planner_root.ast.Expr{ .Int = 3 };
    var v4 = planner_root.ast.Expr{ .Int = 4 };
    const p1 = planner_root.ast.Property{ .key = "a", .value = &v1 };
    const p2 = planner_root.ast.Property{ .key = "b", .value = &v2 };
    const p3 = planner_root.ast.Property{ .key = "c", .value = &v3 };
    const p4 = planner_root.ast.Property{ .key = "d", .value = &v4 };
    const rel = planner_root.ast.RelPattern{ .name = null, .types = &.{}, .props = null, .dir = .right };

    // Z (zero props)
    var qZ = base;
    const leftZ = planner_root.ast.NodePattern{ .name = "n", .labels = &.{"L"}, .props = null };
    const right = planner_root.ast.NodePattern{ .name = null, .labels = &.{}, .props = null };
    const hopZ = planner_root.ast.Hop{ .left = leftZ, .rel = rel, .right = right };
    const chainZ = planner_root.ast.Chain{ .name = null, .hops = &.{hopZ} };
    qZ.match = .{ .chains = &.{chainZ} };
    const kZ = try structural_key.deriveStructuralKey(gpa.allocator(), qZ);
    defer gpa.allocator().free(kZ);
    try std.testing.expect(std.mem.indexOf(u8, kZ, "SZ") != null);

    // L (one prop)
    var qL = base;
    const leftL = planner_root.ast.NodePattern{ .name = "n", .labels = &.{"L"}, .props = &.{p1} };
    const hopL = planner_root.ast.Hop{ .left = leftL, .rel = rel, .right = right };
    const chainL = planner_root.ast.Chain{ .name = null, .hops = &.{hopL} };
    qL.match = .{ .chains = &.{chainL} };
    const kL = try structural_key.deriveStructuralKey(gpa.allocator(), qL);
    defer gpa.allocator().free(kL);
    try std.testing.expect(std.mem.indexOf(u8, kL, "SL") != null);

    // M (2-3 props)
    var qM = base;
    const leftM = planner_root.ast.NodePattern{ .name = "n", .labels = &.{"L"}, .props = &.{ p1, p2 } };
    const hopM = planner_root.ast.Hop{ .left = leftM, .rel = rel, .right = right };
    const chainM = planner_root.ast.Chain{ .name = null, .hops = &.{hopM} };
    qM.match = .{ .chains = &.{chainM} };
    const kM = try structural_key.deriveStructuralKey(gpa.allocator(), qM);
    defer gpa.allocator().free(kM);
    try std.testing.expect(std.mem.indexOf(u8, kM, "SM") != null);

    // H (4+ props)
    var qH = base;
    const leftH = planner_root.ast.NodePattern{ .name = "n", .labels = &.{"L"}, .props = &.{ p1, p2, p3, p4 } };
    const hopH = planner_root.ast.Hop{ .left = leftH, .rel = rel, .right = right };
    const chainH = planner_root.ast.Chain{ .name = null, .hops = &.{hopH} };
    qH.match = .{ .chains = &.{chainH} };
    const kH = try structural_key.deriveStructuralKey(gpa.allocator(), qH);
    defer gpa.allocator().free(kH);
    try std.testing.expect(std.mem.indexOf(u8, kH, "SH") != null);
}

// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheStructuralKeyDegreeBucketEnrichment; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_PathCacheStructuralKeyDegreeBucketEncoding; OWNER=planner; UPDATED=2025-09-21
test "TestCANARY_REQ_GQL_021_PathCacheStructuralKeyDegreeBucketEncoding" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    // Single hop pattern; ensure DB<bucket> appears twice (left/right) in key (L for single occurrence).
    var q: planner_root.ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = null, .having = null, .ret = .{ .items = &.{}, .distinct = false }, .order_by = null, .limit = null, .offset = null };
    const left = planner_root.ast.NodePattern{ .name = "n", .labels = &.{"L"}, .props = null };
    const right = planner_root.ast.NodePattern{ .name = null, .labels = &.{"R"}, .props = null };
    const rel = planner_root.ast.RelPattern{ .name = null, .types = &.{}, .props = null, .dir = .right };
    const hop = planner_root.ast.Hop{ .left = left, .rel = rel, .right = right };
    const chain = planner_root.ast.Chain{ .name = null, .hops = &.{hop} };
    q.match = .{ .chains = &.{chain} };
    const key = try structural_key.deriveStructuralKey(gpa.allocator(), q);
    defer gpa.allocator().free(key);
    const first = std.mem.indexOf(u8, key, "DBL") orelse return error.NotFound;
    const second = std.mem.indexOfPos(u8, key, first + 3, "DB") orelse return error.NotFound; // second bucket may also be L
    try std.testing.expect(second > first);
}

// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheDegreeBucketDiscrimination; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_PathCacheDegreeBucketDiscrimination; OWNER=planner; UPDATED=2025-09-21
test "TestCANARY_REQ_GQL_021_PathCacheDegreeBucketDiscrimination" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    // Build two queries: one with a node appearing once (degree=1 -> L), another where same named node appears in three hops (degree=3 -> M).
    // Query A: (a)-[]->(b)
    var qa: planner_root.ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = null, .having = null, .ret = .{ .items = &.{}, .distinct = false }, .order_by = null, .limit = null, .offset = null };
    const a1 = planner_root.ast.NodePattern{ .name = "x", .labels = &.{"L"}, .props = null };
    const b1 = planner_root.ast.NodePattern{ .name = "b", .labels = &.{"L"}, .props = null };
    const rel_ab = planner_root.ast.RelPattern{ .name = null, .types = &.{}, .props = null, .dir = .right };
    const hop_ab = planner_root.ast.Hop{ .left = a1, .rel = rel_ab, .right = b1 };
    const chain_ab = planner_root.ast.Chain{ .name = null, .hops = &.{hop_ab} };
    qa.match = .{ .chains = &.{chain_ab} };

    // Query B: (x)-[]->(b1); (x)-[]->(b2); (x)-[]->(b3) in a single chain of sequential hops referencing same left name 'x'.
    var qb = qa; // start with base structure
    const xnode = a1; // name = x
    const b2 = planner_root.ast.NodePattern{ .name = "b2", .labels = &.{"L"}, .props = null };
    const b3 = planner_root.ast.NodePattern{ .name = "b3", .labels = &.{"L"}, .props = null };
    const hop1 = planner_root.ast.Hop{ .left = xnode, .rel = rel_ab, .right = b1 };
    const hop2 = planner_root.ast.Hop{ .left = xnode, .rel = rel_ab, .right = b2 };
    const hop3 = planner_root.ast.Hop{ .left = xnode, .rel = rel_ab, .right = b3 };
    const chain_multi = planner_root.ast.Chain{ .name = null, .hops = &.{ hop1, hop2, hop3 } };
    qb.match = .{ .chains = &.{chain_multi} };

    const keyA = try structural_key.deriveStructuralKey(gpa.allocator(), qa);
    defer gpa.allocator().free(keyA);
    const keyB = try structural_key.deriveStructuralKey(gpa.allocator(), qb);
    defer gpa.allocator().free(keyB);
    // Expect keyB to contain DBM for node x while keyA contains only DBL for x.
    try std.testing.expect(std.mem.indexOf(u8, keyA, "DBL") != null);
    try std.testing.expect(std.mem.indexOf(u8, keyB, "DBM") != null);
    try std.testing.expect(!std.mem.eql(u8, keyA, keyB));
}

// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheDegreeBucketUtilizationVarianceEnvelope; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_021_PathCacheStructuralKeyDegreeBucketEncoding; BENCH=BenchmarkCANARY_REQ_GQL_021_PathCacheDegreeBucketUtilizationVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21
test "BenchmarkCANARY_REQ_GQL_021_PathCacheDegreeBucketUtilizationVarianceEnvelope" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    const total_variants: usize = 96;
    const repetitions_per_variant: usize = 6;
    const total_samples = total_variants * repetitions_per_variant;
    var samples = try ally.alloc(u64, total_samples);
    defer ally.free(samples);
    var idx: usize = 0;
    var v: usize = 0;
    while (v < total_variants) : (v += 1) {
        // Fabricate a query whose repetition count influences degree distribution for named node 'x'
        // Alternate between simple single-hop and multi-hop referencing same left node to exercise L vs M buckets.
        var q: planner_root.ast.Query = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = null, .having = null, .ret = .{ .items = &.{}, .distinct = false }, .order_by = null, .limit = null, .offset = null };
        const rel = planner_root.ast.RelPattern{ .name = null, .types = &.{}, .props = null, .dir = .right };
        if ((v & 1) == 0) {
            const left = planner_root.ast.NodePattern{ .name = "x", .labels = &.{"L"}, .props = null };
            const right = planner_root.ast.NodePattern{ .name = "y", .labels = &.{"L"}, .props = null };
            const hop = planner_root.ast.Hop{ .left = left, .rel = rel, .right = right };
            const chain = planner_root.ast.Chain{ .name = null, .hops = &.{hop} };
            q.match = .{ .chains = &.{chain} };
        } else {
            const left = planner_root.ast.NodePattern{ .name = "x", .labels = &.{"L"}, .props = null };
            const r1 = planner_root.ast.NodePattern{ .name = "y1", .labels = &.{"L"}, .props = null };
            const r2 = planner_root.ast.NodePattern{ .name = "y2", .labels = &.{"L"}, .props = null };
            const r3 = planner_root.ast.NodePattern{ .name = "y3", .labels = &.{"L"}, .props = null };
            const h1 = planner_root.ast.Hop{ .left = left, .rel = rel, .right = r1 };
            const h2 = planner_root.ast.Hop{ .left = left, .rel = rel, .right = r2 };
            const h3 = planner_root.ast.Hop{ .left = left, .rel = rel, .right = r3 };
            const chain = planner_root.ast.Chain{ .name = null, .hops = &.{ h1, h2, h3 } };
            q.match = .{ .chains = &.{chain} };
        }
        var r: usize = 0;
        while (r < repetitions_per_variant) : (r += 1) {
            const t0 = compat_nanoTimestamp();
            const key = structural_key.deriveStructuralKey(ally, q) catch break;
            // Scan for DB markers
            var acc: usize = 0;
            var pos: usize = 0;
            while (pos + 1 < key.len) : (pos += 1) {
                if (key[pos] == 'D' and key[pos + 1] == 'B') acc +%= 1;
            }
            if (acc == 0xFFFF) std.mem.doNotOptimizeAway(&acc);
            ally.free(key);
            const t1 = compat_nanoTimestamp();
            samples[idx] = @intCast(t1 - t0);
            idx += 1;
        }
    }
    // Stats
    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const mean = @as(f128, @floatFromInt(sum)) / @as(f128, @floatFromInt(samples.len));
    var acc: f128 = 0;
    for (samples) |s| {
        const sf = @as(f128, @floatFromInt(s));
        const d = sf - mean;
        acc += d * d;
    }
    const variance = acc / @as(f128, @floatFromInt(samples.len));
    const stddev = std.math.sqrt(variance);
    const cv = stddev / mean;
    const tmp = try ally.alloc(u64, samples.len);
    defer ally.free(tmp);
    std.mem.copy(u64, tmp, samples);
    std.sort.pdq(u64, tmp, {}, comptime std.sort.asc(u64));
    const p95 = tmp[@min(tmp.len - 1, (tmp.len * 95) / 100)];
    const p95_ratio = @as(f128, @floatFromInt(p95)) / mean;
    if (cv > 0.22 or p95_ratio > 2.55) return error.VarianceEnvelopeBreached;
    std.debug.print(
        "VARIANCE_OK PathCacheDegreeBucketUtilizationVarianceEnvelope mean={d:.2} cv={d:.4} p95_ratio={d:.2} samples={d}\n",
        .{ mean, cv, p95_ratio, samples.len },
    );
}
