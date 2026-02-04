const std = @import("std");
// CANARY: REQ=REQ-GQL-028; FEATURE="Snapshot Adaptive Policy"; ASPECT=SnapshotAdaptivePolicyLatencyVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_028_SnapshotAdaptivePolicyLatencyVarianceEnvelope; OWNER=storage; UPDATED=2026-02-04

// Synthetic variance benchmark for snapshot adaptive policy latency. We simulate batches of writes
// with variable size and apply an adaptive flush heuristic (threshold adjusts based on moving avg).
// Goal: latency stability across runs (low CV) and bounded p95 relative to mean.

fn simulateSnapshotAdaptive(batch_count: usize, base_threshold: u64) u64 {
    var total_flush_latency: u64 = 0;
    var dyn_threshold = base_threshold;
    var i: usize = 0;
    var seed: u64 = 0x1234_5678_abcd_ef90;
    while (i < batch_count) : (i += 1) {
        // xorshift64* for reproducible pseudo-random variability
        seed ^= seed >> 12;
        seed ^= seed << 25;
        seed ^= seed >> 27;
        const size = (seed *% 0x2545F4914F6CDD1D) >> 8; // spread
        const record_bytes = 256 + (size & 0x3FFF); // 256..16639
        // Adjust threshold: if previous record larger than threshold, increase, else slight decay
        if (record_bytes > dyn_threshold) {
            dyn_threshold = (dyn_threshold + record_bytes) / 2 + 64;
        } else if (dyn_threshold > base_threshold) {
            dyn_threshold -%= (dyn_threshold - base_threshold) / 8 + 1;
        }
        // Latency model: base cost + write amplification factor
        const flush_latency = (record_bytes / 8) + (dyn_threshold / 32);
        total_flush_latency +%= flush_latency;
    }
    return total_flush_latency;
}

test "BenchmarkCANARY_REQ_GQL_028_SnapshotAdaptivePolicyLatencyVarianceEnvelope" {
    const Runs = 30;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const start = std.time.nanoTimestamp();
        _ = simulateSnapshotAdaptive(12_000, 4096);
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

    // Threshold: CV < 0.22, p95 < 2.6x mean (adaptive policy more variable than hot path)
    try std.testing.expect(cv < 0.22);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.6);

    const stderr = std.io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"snapshot_adaptive_policy_latency_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
