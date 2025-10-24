const std = @import("std");

// CANARY: REQ=REQ-GQL-028; FEATURE="WAL Page Flush Queue Depth"; ASPECT=WALPageFlushQueueDepthVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_028_WALPageFlushQueueDepthVarianceEnvelope; OWNER=storage; UPDATED=2025-09-21

// Simulate queue depth dynamics for WAL page flush scheduling.
// Model components:
//  - Incoming dirty pages per tick (Poisson-like via simple LCG modulation)
//  - Flush dispatcher draining at near-constant rate with small jitter
//  - Occasional burst causing temporary depth spike
// We measure the time to process a fixed number of ticks while tracking depth oscillations.

inline fn lcgNext(seed_ptr: *u64) u32 {
    seed_ptr.* = seed_ptr.* * 6364136223846793005 + 0x9E3779B97F4A7C15;
    return @intCast((seed_ptr.* >> 32) & 0xFFFFFFFF);
}

fn simulateQueueWindow(ticks: usize) u64 {
    var seed: u64 = 0xDEADBEEF12345678 ^ @as(u64, ticks);
    var depth: i64 = 0;
    var max_depth: i64 = 0;
    var processed: u64 = 0;
    var t: usize = 0;
    while (t < ticks) : (t += 1) {
        const r = lcgNext(&seed);
        // arrivals: base 4..7 pages, plus rare burst (every ~17th tick adds extra 20-40)
        const base_arr: i64 = 4 + @as(i64, @intCast(@as(u32, (r % 4))));
        var extra: i64 = 0;
        if ((t % 17) == 0 and (r & 0x3) == 0) {
            const burst = @as(u32, (r >> 8) % 21);
            extra = 20 + @as(i64, @intCast(burst));
        }
        const arrivals: i64 = base_arr + extra;
        // service: drain 5..7 pages (slightly less than average arrival during burst)
        const service: i64 = 5 + @as(i64, @intCast(@as(u32, (r >> 16) % 3)));
        depth += arrivals - service;
        if (depth < 0) depth = 0;
        if (depth > max_depth) max_depth = depth;
        processed += @intCast(service);
    }
    // Convert metrics into an approximate latency proxy in ns: combine processed and peak depth.
    // Higher peak depth increases cost superlinearly (simulate contention / lock convoy effect).
    return processed + @as(u64, max_depth * max_depth); // simple proxy
}

test "BenchmarkCANARY_REQ_GQL_028_WALPageFlushQueueDepthVarianceEnvelope" {
    const Runs = 30;
    var samples: [Runs]u64 = undefined;
    var i: usize = 0;
    while (i < Runs) : (i += 1) {
        const start = std.time.nanoTimestamp();
        _ = simulateQueueWindow(220 + i % 7); // vary tick window slightly
        const end = std.time.nanoTimestamp();
        samples[i] = @intCast(end - start);
    }
    // stats
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
    for (samples, 0..) |s, idx| sorted[idx] = s;
    std.sort.heap(u64, &sorted, {}, comptime std.sort.asc(u64));
    const p95 = sorted[@min(sorted.len - 1, (sorted.len * 95) / 100)];

    // Thresholds (per NEXT.md S-001): CV<=0.20 p95/mean<=2.45
    std.debug.print("benchmark=wal_page_flush_queue_depth_variance mean_ns={} cv={:.4} p95_ns={} p95_mean_ratio={:.3}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95, (@as(f128, @floatFromInt(p95)) / mean) });
    try std.testing.expect(cv <= 0.20);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) <= mean * 2.45);
}
