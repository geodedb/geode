// CANARY: REQ=REQ-GQL-012; FEATURE="GROUP BY/Aggregation"; ASPECT=HashAggDistinctMergeVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_012_HashAggDistinctMergeVarianceEnvelope; OWNER=engine; UPDATED=2025-09-21
const std = @import("std");
const exec = @import("../src/exec.zig");

// Benchmark merges multiple spilled segments with overlapping distinct sets to measure variance.
// Guard: CV <= 0.22; p95/mean <= 2.55.

fn runOnce(allocator: std.mem.Allocator) !u64 {
    var timer = try std.time.Timer.start();
    var agg = exec.HashAggregator.init(allocator, 512);
    defer agg.deinit();
    const key_val = exec.BindingValue{ .Int = 1 };
    const spec = [_]exec.Agg{.CountDistinct};
    // Generate two segments with overlap
    var i: usize = 0;
    while (i < 1500) : (i += 1) { // more rows to amplify timing signal
        var ks = [_]exec.BindingValue{key_val};
        var inp = [_]exec.BindingValue{.{ .Int = @intCast(i % 500) }};
        try agg.addRow(&ks, &inp, &spec);
        if (i == 750) try agg.flushSegment(&spec);
    }
    try agg.flushSegment(&spec);
    const rows = try agg.getResults();
    // basic sanity check
    if (rows.len != 1) return error.UnexpectedRowCount;
    return timer.read();
}

pub fn BenchmarkCANARY_REQ_GQL_012_HashAggDistinctMergeVarianceEnvelope() !void {
    const allocator = std.heap.page_allocator;
    const iters: usize = 40; // sample size
    var samples = try allocator.alloc(u64, iters);
    defer allocator.free(samples);
    var i: usize = 0;
    while (i < iters) : (i += 1) samples[i] = try runOnce(allocator);
    // compute stats
    var min: u64 = samples[0];
    var max: u64 = samples[0];
    var total: f128 = 0;
    i = 0;
    while (i < iters) : (i += 1) {
        if (samples[i] < min) min = samples[i];
        if (samples[i] > max) max = samples[i];
        total += @floatFromInt(samples[i]);
    }
    const iters_f: f128 = @floatFromInt(iters);
    const mean = total / iters_f;
    // std dev
    var var_acc: f128 = 0;
    i = 0;
    while (i < iters) : (i += 1) {
        const diff = @as(f128, @floatFromInt(samples[i])) - mean;
        var_acc += diff * diff;
    }
    const variance = var_acc / iters_f;
    const stddev = @sqrt(variance);
    const cv = stddev / mean;
    // approximate p95 by partial sort copy
    const sorted = try allocator.alloc(u64, iters);
    defer allocator.free(sorted);
    std.mem.copy(u64, sorted, samples);
    std.sort.heap(u64, sorted, {}, std.sort.asc(u64));
    const idx95 = (iters * 95) / 100;
    const p95 = sorted[idx95];
    const ratio = (@as(f128, @floatFromInt(p95))) / mean;

    if (cv > 0.22 or ratio > 2.55) {
        std.debug.print("Variance guard breach distinct_merge cv={d:.3} p95/mean={d:.3}\n", .{ cv, ratio });
        return error.VarianceGuardBreach;
    }
}
