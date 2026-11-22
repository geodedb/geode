const std = @import("std");
const perf_gate = @import("perf_gate");

// Zig 0.16 compat helpers for test code
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}
fn compat_sleep(ns: u64) void {
    var req: std.posix.timespec = .{ .sec = 0, .nsec = @intCast(ns) };
    var rem: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.nanosleep(@ptrCast(&req), @ptrCast(&rem));
    } else {
        _ = std.c.nanosleep(&req, &rem);
    }
}

const enumerator_mod = @import("planner_enumerator");

// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanEnumerationCostPrune; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_PlanEnumerationCostPrune; BENCH=BenchmarkCANARY_REQ_GQL_024_PlanEnumerationCostPruneVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanEnumerationCostPruneVarianceEnvelope; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_024_PlanEnumerationCostPrune; BENCH=BenchmarkCANARY_REQ_GQL_024_PlanEnumerationCostPruneVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22

// SONNY-2394: the children arrays must outlive this call. They used to be a
// local `[2]LogicalPlan` in each recursive frame, so the returned tree pointed
// into dead stack frames and the enumerator crashed (GPF) walking it.
fn buildDeepTree(a: std.mem.Allocator, depth: usize, leaf: enumerator_mod.LogicalPlan) !enumerator_mod.LogicalPlan {
    if (depth == 0) return leaf;
    const children = try a.alloc(enumerator_mod.LogicalPlan, 2);
    children[0] = try buildDeepTree(a, depth - 1, leaf);
    children[1] = leaf;
    return enumerator_mod.LogicalPlan{ .op = .join, .children = children };
}

test "TestCANARY_REQ_GQL_024_PlanEnumerationCostPrune" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var tree_arena = std.heap.ArenaAllocator.init(alloc);
    defer tree_arena.deinit();
    const leaf = enumerator_mod.LogicalPlan{ .op = .scan, .children = &[_]enumerator_mod.LogicalPlan{} };
    const root = try buildDeepTree(tree_arena.allocator(), 4, leaf); // depth 4 tree

    var enum_prune = enumerator_mod.PlanEnumerator.init(alloc, .{ .max_plans = 1024, .enable_prune = true, .prune_factor = 1.2 });
    defer enum_prune.deinit();
    var enum_full = enumerator_mod.PlanEnumerator.init(alloc, .{ .max_plans = 1024, .enable_prune = false });
    defer enum_full.deinit();

    var list_prune = std.ArrayList(enumerator_mod.CandidatePlan).empty;
    defer list_prune.deinit(alloc);
    var list_full = std.ArrayList(enumerator_mod.CandidatePlan).empty;
    defer list_full.deinit(alloc);
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
}

const PruneBench = struct {
    root: enumerator_mod.LogicalPlan,
    alloc: std.mem.Allocator,

    fn run(self: *PruneBench, prune: bool) !usize {
        var e = enumerator_mod.PlanEnumerator.init(self.alloc, if (prune)
            .{ .max_plans = 2048, .enable_prune = true, .prune_factor = 1.3 }
        else
            .{ .max_plans = 2048, .enable_prune = false });
        defer e.deinit();
        var list = std.ArrayList(enumerator_mod.CandidatePlan).empty;
        defer list.deinit(self.alloc);
        try e.enumerateUnmanaged(self.root, self.alloc, &list);
        return list.items.len;
    }

    fn pruned(self: *PruneBench) !usize {
        return self.run(true);
    }

    fn full(self: *PruneBench) !usize {
        return self.run(false);
    }
};

test "BenchmarkCANARY_REQ_GQL_024_PlanEnumerationCostPruneVarianceEnvelope" {
    // SONNY-2439: batched samples from the production allocator, the pruned
    // and full arms interleaved, robust statistics -- see tests/perf_gate.zig.
    const alloc = perf_gate.bench_allocator;
    var tree_arena = std.heap.ArenaAllocator.init(alloc);
    defer tree_arena.deinit();
    const leaf = enumerator_mod.LogicalPlan{ .op = .scan, .children = &[_]enumerator_mod.LogicalPlan{} };
    const root = try buildDeepTree(tree_arena.allocator(), 5, leaf);

    var bench: PruneBench = .{ .root = root, .alloc = alloc };
    var samples_prune: [32]f64 = undefined;
    var samples_full: [32]f64 = undefined;
    _ = try perf_gate.timeBatch(&bench, PruneBench.pruned, 4);
    _ = try perf_gate.timeBatch(&bench, PruneBench.full, 4);
    try perf_gate.interleavedAB(&bench, PruneBench.pruned, PruneBench.full, 4, &samples_prune, &samples_full);
    const sp = perf_gate.robust(&samples_prune);
    const sf = perf_gate.robust(&samples_full);
    // Perf claims go through the shared gate (SONNY-2394): reported unless
    // GEODE_PERF_GATES=enforce (SONNY-2439) -- see tests/perf_gate.zig.
    // Correctness assertions in this file are not gated.
    try perf_gate.robustEnvelope("pruned enumeration", sp, 0.30, 2.55);
    try perf_gate.robustEnvelope("full enumeration", sf, 0.30, 2.55);
    // Expect pruning to be no worse than 1.15x full enumeration (medians).
    const prune_over_full = if (sf.median > 0) sp.median / sf.median else 0;
    std.debug.print("CANARY_PRUNE median_pruned={d:.1}ns median_full={d:.1}ns pruned/full={d:.3}\n", .{ sp.median, sf.median, prune_over_full });
    try perf_gate.check("pruned median <= 1.15x full", prune_over_full <= 1.15, "pruned/full={d:.3}", .{prune_over_full});
}
