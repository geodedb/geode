const std = @import("std");
const enumerator_mod = @import("planner_enumerator");

// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanEnumerationCostPrune; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_PlanEnumerationCostPrune; BENCH=BenchmarkCANARY_REQ_GQL_024_PlanEnumerationCostPruneVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanEnumerationCostPruneVarianceEnvelope; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_024_PlanEnumerationCostPrune; BENCH=BenchmarkCANARY_REQ_GQL_024_PlanEnumerationCostPruneVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22

fn buildDeepTree(depth: usize, leaf: enumerator_mod.LogicalPlan) enumerator_mod.LogicalPlan {
    if (depth == 0) return leaf;
    var children: [2]enumerator_mod.LogicalPlan = .{ buildDeepTree(depth - 1, leaf), leaf };
    return enumerator_mod.LogicalPlan{ .op = .join, .children = children[0..] };
}

test "TestCANARY_REQ_GQL_024_PlanEnumerationCostPrune" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const leaf = enumerator_mod.LogicalPlan{ .op = .scan, .children = &[_]enumerator_mod.LogicalPlan{} };
    const root = buildDeepTree(4, leaf); // depth 4 tree

    var enum_prune = enumerator_mod.PlanEnumerator.init(alloc, .{ .max_plans = 1024, .enable_prune = true, .prune_factor = 1.2 });
    var enum_full = enumerator_mod.PlanEnumerator.init(alloc, .{ .max_plans = 1024, .enable_prune = false });

    var list_prune = std.ArrayListUnmanaged(enumerator_mod.CandidatePlan){};
    var list_full = std.ArrayListUnmanaged(enumerator_mod.CandidatePlan){};
    try enum_prune.enumerateUnmanaged(root, alloc, &list_prune);
    try enum_full.enumerateUnmanaged(root, alloc, &list_full);

    // Expect pruning to generate fewer or equal plans
    try std.testing.expect(list_prune.items.len <= list_full.items.len);
    // Both must have at least one candidate, and best cost from pruned set should be near global best (within prune_factor)
    try std.testing.expect(list_prune.items.len > 0 and list_full.items.len > 0);
    var best_full = list_full.items[0].cost;
    for (list_full.items) |cp| {
        if (cp.cost < best_full) best_full = cp.cost;
    }
    var best_prune = list_prune.items[0].cost;
    for (list_prune.items) |cp| {
        if (cp.cost < best_prune) best_prune = cp.cost;
    }
    try std.testing.expect(best_prune <= best_full * 1.2 + 0.0001);

    list_prune.deinit(alloc);
    list_full.deinit(alloc);
}

test "BenchmarkCANARY_REQ_GQL_024_PlanEnumerationCostPruneVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const leaf = enumerator_mod.LogicalPlan{ .op = .scan, .children = &[_]enumerator_mod.LogicalPlan{} };
    const root = buildDeepTree(5, leaf);
    const iterations: usize = 64;
    var samples_prune = try alloc.alloc(u64, iterations); defer alloc.free(samples_prune);
    var samples_full = try alloc.alloc(u64, iterations); defer alloc.free(samples_full);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var ep = enumerator_mod.PlanEnumerator.init(alloc, .{ .max_plans = 2048, .enable_prune = true, .prune_factor = 1.3 });
        var ef = enumerator_mod.PlanEnumerator.init(alloc, .{ .max_plans = 2048, .enable_prune = false });
        var lp = std.ArrayListUnmanaged(enumerator_mod.CandidatePlan){};
        var lf = std.ArrayListUnmanaged(enumerator_mod.CandidatePlan){};
        const start_p = std.time.nanoTimestamp();
        try ep.enumerateUnmanaged(root, alloc, &lp);
        const end_p = std.time.nanoTimestamp();
        samples_prune[i] = @as(u64, @intCast(end_p - start_p));
        const start_f = std.time.nanoTimestamp();
        try ef.enumerateUnmanaged(root, alloc, &lf);
        const end_f = std.time.nanoTimestamp();
        samples_full[i] = @as(u64, @intCast(end_f - start_f));
        lp.deinit(alloc); lf.deinit(alloc);
    }
    // stats helper (top-level definitions below)
    const sp = stats(samples_prune);
    const sf = stats(samples_full);
    try std.testing.expect(sp.cv <= 0.22 and sp.p95_mean <= 2.55);
    try std.testing.expect(sf.cv <= 0.22 and sf.p95_mean <= 2.55);
    // Expect pruning mean to be no worse than 1.15x full enumeration
    try std.testing.expect(sp.mean <= sf.mean * 1.15 + 0.0001);
}

const Stats = struct { mean: f128, cv: f128, p95_mean: f128 };

fn stats(a: []const u64) Stats {
    var s: f128 = 0; for (a) |v| s += @as(f128, @floatFromInt(v));
    const mean = s / @as(f128, @floatFromInt(a.len));
    var var_acc: f128 = 0; for (a) |v| { const d = @as(f128,@floatFromInt(v)) - mean; var_acc += d*d; }
    const variance = var_acc / @as(f128, @floatFromInt(a.len));
    var scratch = std.heap.page_allocator.dupe(u64, a) catch unreachable;
    defer std.heap.page_allocator.free(scratch);
    const rank = (a.len * 95) / 100;
    var r: usize = 0;
    while (r <= rank) : (r += 1) {
        var min_i = r;
        var j: usize = r + 1;
        while (j < a.len) : (j += 1) {
            if (scratch[j] < scratch[min_i]) min_i = j;
        }
        if (min_i != r) {
            const tmp = scratch[r];
            scratch[r] = scratch[min_i];
            scratch[min_i] = tmp;
        }
    }
    const p95 = @as(f128, @floatFromInt(scratch[rank]));
    return .{ .mean = mean, .cv = std.math.sqrt(variance)/mean, .p95_mean = p95 / mean };
}
