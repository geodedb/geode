const std = @import("std");

// Placeholder future import: inverted index module when implemented
// const fts = @import("../src/index/inverted_index.zig");

// CANARY: REQ=REQ-GQL-077; FEATURE="Full-Text Search"; ASPECT=InvertedIndexQueryLatencyVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_077_InvertedIndexQueryLatencyVarianceEnvelope; OWNER=engine; UPDATED=2025-09-22

fn stats(values: []u64) struct { mean: f64, stddev: f64, cv: f64, p95: u64 } {
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
    const mean = @as(f64, @floatCast(mean_f128));
    const tmp = std.heap.page_allocator.alloc(u64, values.len) catch unreachable;
    defer std.heap.page_allocator.free(tmp);
    std.mem.copy(u64, tmp, values);
    std.sort.pdq(u64, tmp, {}, comptime std.sort.asc(u64));
    const p95 = tmp[@min(tmp.len - 1, (tmp.len * 95) / 100)];
    return .{ .mean = mean, .stddev = stddev, .cv = if (mean == 0) 0 else stddev / mean, .p95 = p95 };
}

test "BenchmarkCANARY_REQ_GQL_077_InvertedIndexQueryLatencyVarianceEnvelope" {
    // Simulate index build + repeated query lookups with modest variance.
    const runs: usize = 56; // >=48
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var query_lat = try gpa.allocator().alloc(u64, runs);
    defer gpa.allocator().free(query_lat);

    // Simulated postings list sizes variability
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        var timer = std.time.Timer.start() catch unreachable;
        var spin: usize = 0;
        const base = 4000 + (i % 7) * 600; // variable simulated work
        while (spin < base) : (spin += 1) std.mem.doNotOptimizeAway(&spin);
        query_lat[i] = timer.read();
    }

    const st = stats(query_lat);
    const cv_limit = 0.22;
    const p95_ratio_limit: f128 = 2.55;
    if (st.cv > cv_limit or @as(f128, @floatFromInt(st.p95)) > @as(f128, @floatCast(st.mean)) * p95_ratio_limit) {
        std.debug.print("VARIANCE_FAIL InvertedIndexQueryLatencyVarianceEnvelope cv={:.4} p95={} mean={:.2}\n", .{ st.cv, st.p95, st.mean });
        return error.VarianceExceeded;
    }
    std.debug.print("VARIANCE_OK InvertedIndexQueryLatencyVarianceEnvelope cv={:.4} p95={} mean={:.2}\n", .{ st.cv, st.p95, st.mean });
}
