const std = @import("std");

// CANARY: REQ=REQ-GQL-028; FEATURE="WAL I/O Throttle"; ASPECT=WALIOThrottleVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_028_WALIOThrottleVarianceEnvelope; OWNER=storage; UPDATED=2025-09-21

fn simulateThrottle(iterations: usize, target_iops: u32) u64 {
    // Simulate a feedback loop controlling WAL write IOPS by introducing sleep/jitter when rate exceeds target.
    var prng = std.rand.DefaultPrng.init(0x57414C5448524F54); // 'WALTHROT'
    const rand = prng.random();
    var issued: u64 = 0;
    var now_ns: u64 = 0;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Each logical write has a base cost plus random jitter; throttle if instantaneous window too high.
        const base = 900 + rand.intRangeAtMost(u16, 0, 350); // 0.9-1.25us synthetic write cost
        now_ns += base;
        issued += 1;
        // Every 128 ops evaluate rate over synthetic 1ms window.
        if ((issued & 0x7F) == 0) {
            // Approx instantaneous IOPS (scaled) = issued / (now_ns / 1e6)
            const ms = now_ns / 1_000_000 + 1;
            const approx_iops: u64 = (issued * 1_000) / ms; // scaled by 1000 for roughness
            if (approx_iops > target_iops) {
                // Inject backoff proportional to overflow.
                const overflow = approx_iops - target_iops;
                const penalty = overflow * 40; // 40ns per overflow unit
                now_ns += penalty;
            } else if (approx_iops + 200 < target_iops) {
                // Slight acceleration path: reduced jitter (simulate coalescing)
                now_ns += 50; // constant bookkeeping
            }
        }
    }
    return now_ns;
}

test "BenchmarkCANARY_REQ_GQL_028_WALIOThrottleVarianceEnvelope" {
    const Runs = 28;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const start = std.time.nanoTimestamp();
        _ = simulateThrottle(25_000, 120_000); // iterations, target pseudo-IOPS
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
    // Thresholds: CV < 0.21, p95 < 2.45x mean
    try std.testing.expect(cv < 0.21);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.45);
    const stderr = std.io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"wal_io_throttle_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
