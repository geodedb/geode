const std = @import("std");
const pipeline = @import("../src/planner/pipeline.zig");
const path_cache_mod = @import("../src/planner/path_cache.zig");

// CANARY: REQ=REQ-GQL-021; FEATURE="Query Planner"; ASPECT=PlannerPipelineP95MeanVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_021_PlannerPipelineP95MeanVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

fn collectP95(data: []u64) u64 {
    const buf = std.heap.page_allocator.alloc(u64, data.len) catch return 0;
    defer std.heap.page_allocator.free(buf);
    std.mem.copy(u64, buf, data);
    std.sort.pdq(u64, buf, {}, comptime std.sort.asc(u64));
    const idx = @min(buf.len - 1, (buf.len * 95) / 100);
    return buf[idx];
}

fn stats(values: []u64) struct { mean: f128, cv: f64 } {
    var sum: f128 = 0;
    for (values) |v| sum += @as(f128, @floatFromInt(v));
    const mean = sum / @as(f128, @floatFromInt(values.len));
    var var_acc: f128 = 0;
    for (values) |v| {
        const diff = @as(f128, @floatFromInt(v)) - mean;
        var_acc += diff * diff;
    }
    const variance = var_acc / @as(f128, @floatFromInt(values.len));
    const stddev = @sqrt(variance);
    const mean_f64: f64 = @floatCast(mean);
    return .{ .mean = mean, .cv = if (mean_f64 == 0) 0 else @as(f64, @floatCast(stddev)) / mean_f64 };
}

// New variance envelope that also asserts p95/mean ratio thresholds for each phase.
test "BenchmarkCANARY_REQ_GQL_021_PlannerPipelineP95MeanVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var cache = try path_cache_mod.PathCache.init(gpa.allocator(), 16);
    defer cache.deinit();
    const runs = 60;
    var rewrite = try gpa.allocator().alloc(u64, runs);
    defer gpa.allocator().free(rewrite);
    var card = try gpa.allocator().alloc(u64, runs);
    defer gpa.allocator().free(card);
    var cost = try gpa.allocator().alloc(u64, runs);
    defer gpa.allocator().free(cost);
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        const q = switch (i & 3) {
            0 => "RETURN 1",
            1 => "MATCH (a)--(b) RETURN a",
            2 => "MATCH (a)--(b)--(c) RETURN b",
            else => "MATCH (n) RETURN n",
        };
        const res = try pipeline.runPipeline(gpa.allocator(), .{}, &cache, q);
        rewrite[i] = res.timings.rewrite_ns;
        card[i] = res.timings.cardinality_ns;
        cost[i] = res.timings.cost_eval_ns;
    }
    const st_rewrite = stats(rewrite);
    const st_card = stats(card);
    const st_cost = stats(cost);
    const p95_rewrite = collectP95(rewrite);
    const p95_card = collectP95(card);
    const p95_cost = collectP95(cost);
    const mean_rewrite = st_rewrite.mean;
    const mean_card = st_card.mean;
    const mean_cost = st_cost.mean;
    // Convert mean to f128 for ratio checks
    const ratio_rewrite = @as(f128, @floatFromInt(p95_rewrite)) / mean_rewrite;
    const ratio_card = @as(f128, @floatFromInt(p95_card)) / mean_card;
    const ratio_cost = @as(f128, @floatFromInt(p95_cost)) / mean_cost;
    // Thresholds aligned with project policy (p95/mean <= 2.4; cv <= 0.20)
    if (st_rewrite.cv > 0.20 or st_card.cv > 0.20 or st_cost.cv > 0.20 or
        ratio_rewrite > 2.4 or ratio_card > 2.4 or ratio_cost > 2.4)
    {
        std.debug.print("VARIANCE_FAIL PlannerPipelineP95MeanVarianceEnvelope cv_r={:.4} cv_c={:.4} cv_co={:.4} r95={d} c95={d} co95={d}\n", .{ st_rewrite.cv, st_card.cv, st_cost.cv, p95_rewrite, p95_card, p95_cost });
        return error.VarianceExceeded;
    }
    std.debug.print("VARIANCE_OK PlannerPipelineP95MeanVarianceEnvelope cv_r={:.4} cv_c={:.4} cv_co={:.4} r95={d} c95={d} co95={d}\n", .{ st_rewrite.cv, st_card.cv, st_cost.cv, p95_rewrite, p95_card, p95_cost });
}
