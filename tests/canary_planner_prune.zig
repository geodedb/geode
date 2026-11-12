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

test "BenchmarkCANARY_REQ_GQL_024_PlanEnumerationCostPruneVarianceEnvelope" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var tree_arena = std.heap.ArenaAllocator.init(alloc);
    defer tree_arena.deinit();
    const leaf = enumerator_mod.LogicalPlan{ .op = .scan, .children = &[_]enumerator_mod.LogicalPlan{} };
    const root = try buildDeepTree(tree_arena.allocator(), 5, leaf);
    const iterations: usize = 64;
    var samples_prune = try alloc.alloc(u64, iterations);
    defer alloc.free(samples_prune);
    var samples_full = try alloc.alloc(u64, iterations);
    defer alloc.free(samples_full);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var ep = enumerator_mod.PlanEnumerator.init(alloc, .{ .max_plans = 2048, .enable_prune = true, .prune_factor = 1.3 });
        defer ep.deinit();
        var ef = enumerator_mod.PlanEnumerator.init(alloc, .{ .max_plans = 2048, .enable_prune = false });
        defer ef.deinit();
        var lp = std.ArrayList(enumerator_mod.CandidatePlan).empty;
        var lf = std.ArrayList(enumerator_mod.CandidatePlan).empty;
        const start_p = compat_nanoTimestamp();
        try ep.enumerateUnmanaged(root, alloc, &lp);
        const end_p = compat_nanoTimestamp();
        samples_prune[i] = @as(u64, @intCast(end_p - start_p));
        const start_f = compat_nanoTimestamp();
        try ef.enumerateUnmanaged(root, alloc, &lf);
        const end_f = compat_nanoTimestamp();
        samples_full[i] = @as(u64, @intCast(end_f - start_f));
        lp.deinit(alloc);
        lf.deinit(alloc);
    }
    // stats helper (top-level definitions below)
    const sp = stats(samples_prune);
    const sf = stats(samples_full);
    // Perf claims go through the shared gate (SONNY-2394): reported unless
    // GEODE_PERF_GATES=enforce (SONNY-2439) -- see tests/perf_gate.zig.
    // Correctness assertions in this file are not gated.
    try perf_gate.envelope("pruned enumeration", sp.cv, sp.p95_mean, 0.22, 2.55);
    try perf_gate.envelope("full enumeration", sf.cv, sf.p95_mean, 0.22, 2.55);
    // Expect pruning mean to be no worse than 1.15x full enumeration
    const prune_over_full: f64 = @floatCast(sp.mean / sf.mean);
    try perf_gate.check("pruned mean <= 1.15x full", sp.mean <= sf.mean * 1.15 + 0.0001, "pruned/full={d:.3}", .{prune_over_full});
}

const Stats = struct { mean: f128, cv: f128, p95_mean: f128 };

fn stats(a: []const u64) Stats {
    var s: f128 = 0;
    for (a) |v| s += @as(f128, @floatFromInt(v));
    const mean = s / @as(f128, @floatFromInt(a.len));
    var var_acc: f128 = 0;
    for (a) |v| {
        const d = @as(f128, @floatFromInt(v)) - mean;
        var_acc += d * d;
    }
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
    return .{ .mean = mean, .cv = std.math.sqrt(variance) / mean, .p95_mean = p95 / mean };
}
