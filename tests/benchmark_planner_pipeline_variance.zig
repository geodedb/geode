const std = @import("std");
const pipeline = @import("../src/planner/pipeline.zig");
const path_cache_mod = @import("../src/planner/path_cache.zig");

// CANARY: REQ=REQ-GQL-021; FEATURE="Query Planner"; ASPECT=PlannerPipelineVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_021_PlannerPipelineVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

fn lcgNext(state: *u64) u64 {
    state.* = state.* * 6364136223846793005 + 1;
    return state.*;
}

fn stats(values: []u64) struct { mean: f64, stddev: f64, cv: f64 } {
    var sum: f128 = 0;
    for (values) |v| sum += @as(f128, @floatFromInt(v));
    const mean_f128 = sum / @as(f128, @floatFromInt(values.len));
    var var_acc: f128 = 0;
    for (values) |v| {
        const diff = @as(f128, @floatFromInt(v)) - mean_f128;
        var_acc += diff * diff;
    }
    const variance = var_acc / @as(f128, @floatFromInt(values.len));
    const stddev = @as(f64, @floatCast(@sqrt(variance)));
    const mean_cast = @as(f64, @floatCast(mean_f128));
    return .{ .mean = mean_cast, .stddev = stddev, .cv = if (mean_cast == 0) 0 else stddev / mean_cast };
}

test "BenchmarkCANARY_REQ_GQL_021_PlannerPipelineVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var cache = try path_cache_mod.PathCache.init(gpa.allocator(), 32);
    defer cache.deinit();
    const runs = 60;
    var rewrite = try gpa.allocator().alloc(u64, runs);
    defer gpa.allocator().free(rewrite);
    var card = try gpa.allocator().alloc(u64, runs);
    defer gpa.allocator().free(card);
    var cost = try gpa.allocator().alloc(u64, runs);
    defer gpa.allocator().free(cost);
    var hits: u64 = 0;
    var rng: u64 = 1;
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        _ = lcgNext(&rng);
        const q = switch (rng & 3) {
            0 => "RETURN 1 AS x",
            1 => "MATCH (a)--(b) RETURN a",
            2 => "MATCH (a)--(b)--(c) RETURN b",
            else => "MATCH (x) RETURN x",
        };
        const res = try pipeline.runPipeline(gpa.allocator(), .{}, &cache, q);
        rewrite[i] = res.timings.rewrite_ns;
        card[i] = res.timings.cardinality_ns;
        cost[i] = res.timings.cost_eval_ns;
        if (res.cache_hit) hits += 1;
    }
    const st_rewrite = stats(rewrite);
    const st_card = stats(card);
    const st_cost = stats(cost);
    // Thresholds
    if (st_rewrite.cv > 0.20 or st_card.cv > 0.20 or st_cost.cv > 0.20) {
        std.debug.print("VARIANCE_FAIL PlannerPipelineVarianceEnvelope rewrite_cv={:.4} card_cv={:.4} cost_cv={:.4}\n", .{ st_rewrite.cv, st_card.cv, st_cost.cv });
        return error.VarianceExceeded;
    }
    std.debug.print("VARIANCE_OK PlannerPipelineVarianceEnvelope rewrite_cv={:.4} card_cv={:.4} cost_cv={:.4} hits={}\n", .{ st_rewrite.cv, st_card.cv, st_cost.cv, hits });
}
