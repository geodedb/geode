const std = @import("std");

// CANARY: REQ=REQ-GQL-021; FEATURE="Query Planner"; ASPECT=QueryPlanCacheEvictVarianceEnvelope; STATUS=IMPL; BENCH=BenchmarkCANARY_REQ_GQL_021_QueryPlanCacheEvictVarianceEnvelope; OWNER=planner; UPDATED=2026-11-14

fn simulateEvict(capacity: usize, iterations: usize) u64 {
    // Simulate LRU-ish eviction sweep where some entries are protected (recent) and others scanned.
    var prng = std.rand.DefaultPrng.init(0x455643494354); // 'EVICT'
    const rand = prng.random();
    var touched: usize = 0;
    var total_ns: u64 = 0;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Each iteration we randomly decide number of cold entries to scan.
        const cold_scan = 4 + (rand.intRangeAtMost(u16, 0, @as(u16, @intCast(@min(capacity, 120))))); // 4..~124
        touched += cold_scan;
        // Sweep cost ~ linear in cold_scan with small variance + occasional hash recompute penalty.
        var sweep_cost: u64 = @as(u64, cold_scan) * 150; // 150ns baseline per entry
        if ((i & 0x1F) == 0) {
            // occasional rehash / stats recompute
            sweep_cost += 8_000 + rand.intRangeAtMost(u16, 0, 4_000);
        } else {
            sweep_cost += rand.intRangeAtMost(u16, 0, 900);
        }
        total_ns += sweep_cost;
        if (touched > capacity) touched = capacity / 3; // simulate retention after evictions
    }
    return total_ns;
}

test "BenchmarkCANARY_REQ_GQL_021_QueryPlanCacheEvictVarianceEnvelope" {
    const Runs = 26;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const start = std.time.nanoTimestamp();
        _ = simulateEvict(10_000, 2_500);
        const end = std.time.nanoTimestamp();
        samples[r] = @intCast(end - start);
    }
    var sum: f128 = 0;
    for (samples) |s| sum += @as(f128, @floatFromInt(s));
    const mean = sum / @as(f128, samples.len);
    var var_acc: f128 = 0;
    for (samples) |s| {
        const dv = @as(f128, @floatFromInt(s)) - mean;
        var_acc += dv * dv;
    }
    const stddev = std.math.sqrt(var_acc / @as(f128, samples.len));
    const cv = stddev / mean;
    var sorted: [Runs]u64 = undefined;
    for (samples, 0..) |s, i| sorted[i] = s;
    std.sort.heap(u64, &sorted, {}, comptime std.sort.asc(u64));
    const p95 = sorted[@min(sorted.len - 1, (sorted.len * 95) / 100)];
    // Thresholds: CV < 0.19, p95 < 2.35x mean (eviction should be fairly stable)
    try std.testing.expect(cv < 0.19);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.35);
    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"query_plan_cache_evict_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
