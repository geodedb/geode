const std = @import("std");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC"; ASPECT=CDCWatermarkAdvanceVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_042_CDCWatermarkAdvanceVarianceEnvelope; OWNER=cdc; UPDATED=2025-09-21

fn simulateWatermark(streams: usize, events_per_stream: usize) u64 {
    // Simulate computing a global watermark as min over per-stream last-committed timestamps with jitter.
    var prng = std.rand.DefaultPrng.init(0x57415445524D4B); // 'WATERMK'
    const rand = prng.random();
    var total_ns: u64 = 0;
    var s: usize = 0;
    while (s < streams) : (s += 1) {
        // Summation of scanning recent events (simulate ring buffer tail scan)
        var e: usize = 0;
        while (e < events_per_stream) : (e += 1) {
            // Each event contributes a timestamp check + potential histogram update.
            total_ns += 180 + rand.intRangeAtMost(u16, 0, 140);
            if ((e & 0x1F) == 0) {
                // Periodic histogram compaction / GC
                total_ns += 1_700 + rand.intRangeAtMost(u16, 0, 900);
            }
        }
        if ((s & 0x3F) == 0) {
            // Global min recompute overhead
            total_ns += 4_400 + rand.intRangeAtMost(u16, 0, 3_000);
        }
    }
    return total_ns;
}

test "BenchmarkCANARY_REQ_GQL_042_CDCWatermarkAdvanceVarianceEnvelope" {
    const Runs = 24;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const start = std.time.nanoTimestamp();
        _ = simulateWatermark(320, 40);
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
    // Thresholds: CV < 0.21, p95 < 2.5x mean
    try std.testing.expect(cv < 0.21);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.5);
    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"cdc_watermark_advance_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
