const std = @import("std");
const prefetch = @import("../src/benchmarks/pagination_prefetch_sim.zig");

// CANARY: REQ=REQ-GQL-004; FEATURE="Pagination"; ASPECT=PaginationPrefetchVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_004_PaginationPrefetchVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21
// Bench rationale: user-observed page request latency under adaptive prefetch window should be stable.
// Metrics collected: consumer latency ns per page across multiple simulation seeds. We compute CV and p95/mean
// over the non-zero latency subset (since zero-latency prefetched pages dominate) to ensure the tail of misses is stable.

fn collectNonZero(allocator: std.mem.Allocator, data: []prefetch.PageMetric) ![]u64 {
    var count: usize = 0;
    for (data) |m| {
        if (m.consumer_latency_ns > 0) count += 1;
    }
    if (count == 0) count = 1; // avoid zero-length (inject a single 0 latency placeholder)
    var out = try allocator.alloc(u64, count);
    var idx: usize = 0;
    if (count == 1) {
        // Either truly one non-zero or none; we will fill placeholder below.
    }
    for (data) |m| {
        if (m.consumer_latency_ns > 0) {
            out[idx] = m.consumer_latency_ns;
            idx += 1;
        }
    }
    if (idx == 0) out[0] = 1; // placeholder minimal latency
    return out;
}

fn stats(values: []u64) struct { mean: f64, cv: f64, p95: u64 } {
    var sum: f128 = 0;
    for (values) |v| sum += @as(f128, @floatFromInt(v));
    const mean_f128 = sum / @as(f128, @floatFromInt(values.len));
    var var_acc: f128 = 0;
    for (values) |v| {
        const diff = @as(f128, @floatFromInt(v)) - mean_f128;
        var_acc += diff * diff;
    }
    const variance = if (values.len > 1) var_acc / @as(f128, @floatFromInt(values.len)) else 0;
    const stddev = @as(f64, @floatCast(@sqrt(variance)));
    const mean = @as(f64, @floatCast(mean_f128));
    // p95
    const tmp = std.heap.page_allocator.alloc(u64, values.len) catch unreachable;
    defer std.heap.page_allocator.free(tmp);
    std.mem.copy(u64, tmp, values);
    std.sort.pdq(u64, tmp, {}, comptime std.sort.asc(u64));
    const p95 = tmp[@min(tmp.len - 1, (tmp.len * 95) / 100)];
    return .{ .mean = mean, .cv = if (mean == 0) 0 else stddev / mean, .p95 = p95 };
}

test "BenchmarkCANARY_REQ_GQL_004_PaginationPrefetchVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    const runs = 40;
    var rng_seed: u64 = 9;
    var latencies_list = try ally.alloc([]u64, runs); // store slices for concatenation
    defer ally.free(latencies_list);
    var total_non_zero: usize = 0;
    var r: usize = 0;
    while (r < runs) : (r += 1) {
        rng_seed = rng_seed * 6364136223846793005 + 1;
        const metrics = try prefetch.runSimulation(ally, .{ .window = 3, .pages = 20, .page_size = 96 }, rng_seed);
        defer ally.free(metrics);
        const nz = try collectNonZero(ally, metrics);
        latencies_list[r] = nz;
        total_non_zero += nz.len;
    }
    // Flatten
    var all = try ally.alloc(u64, total_non_zero);
    defer ally.free(all);
    var offset: usize = 0;
    for (latencies_list) |slice| {
        std.mem.copyForwards(u64, all[offset .. offset + slice.len], slice);
        ally.free(slice);
        offset += slice.len;
    }
    const st = stats(all);
    const ratio = if (st.mean == 0) 0 else @as(f64, @floatFromInt(@as(u64, @intFromFloat(st.p95)))) / st.mean;
    if (st.cv > 0.22 or ratio > 2.55) {
        std.debug.print("VARIANCE_FAIL PaginationPrefetchVarianceEnvelope cv={:.4} p95={} mean={:.2} ratio={:.2}\n", .{ st.cv, st.p95, st.mean, ratio });
        return error.VarianceExceeded;
    }
    std.debug.print("VARIANCE_OK PaginationPrefetchVarianceEnvelope cv={:.4} p95={} mean={:.2} ratio={:.2} samples={}\n", .{ st.cv, st.p95, st.mean, ratio, all.len });
}
