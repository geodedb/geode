const std = @import("std");
const qd_mod = @import("../src/storage/queue_depth.zig");

// CANARY: REQ=REQ-GQL-028; FEATURE="Snapshot Flush Queue Depth"; ASPECT=SnapshotFlushQueueDepthVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_028_SnapshotFlushQueueDepthVarianceEnvelope; OWNER=storage; UPDATED=2026-02-04
// Benchmark rationale: Ensure enqueue/dequeue path and sampling remain stable (low variance) under
// synthetic contention pattern approximating burst flush scheduling and steady draining.
// Thresholds: CV < 0.22, p95/mean < 2.4.

fn simulateWork(qd: *qd_mod.QueueDepth, iteration: usize) void {
    // Burst size pattern with mild deterministic jitter (bit-mixing iteration index)
    var seed: u64 = 0xA51E_1B59 ^ (@as(u64, iteration) *% 0x9E3779B97F4A7C15);
    seed ^= seed >> 27;
    seed ^= seed << 19;
    seed ^= seed >> 33;
    const burst: u32 = @intCast(8 + (seed & 0xF)); // 8-23
    var i: u32 = 0;
    while (i < burst) : (i += 1) qd.inc();
    // Partial drain (simulate flush threads consuming pages)
    var drain: u32 = burst / 2;
    while (drain > 0) : (drain -= 1) qd.dec();
    // Residual stays enqueued to influence max watermark periodically drain remainder
    if ((iteration % 7) == 0) {
        var left = burst - (burst / 2);
        while (left > 0) : (left -= 1) qd.dec();
    }
}

test "BenchmarkCANARY_REQ_GQL_028_SnapshotFlushQueueDepthVarianceEnvelope" {
    const Runs = 40;
    var qd: qd_mod.QueueDepth = .{};
    var samples: [Runs]u64 = undefined;
    var iter: usize = 0;
    while (iter < Runs) : (iter += 1) {
        const start = std.time.nanoTimestamp();
        var inner: usize = 0;
        while (inner < 64) : (inner += 1) simulateWork(&qd, iter * 64 + inner);
        // Perform sampling sweep (lightweight) to mimic periodic metrics scrape.
        var buf: [8]qd_mod.Sample = undefined;
        var sampler = qd_mod.Sampler.init(&qd);
        _ = sampler.collect(&buf);
        const end = std.time.nanoTimestamp();
        samples[iter] = @intCast(end - start);
    }
    // Compute statistics (mean, stddev, CV, p95)
    var sum: f128 = 0;
    for (samples) |s| sum += @as(f128, @floatFromInt(s));
    const mean = sum / @as(f128, samples.len);
    var var_acc: f128 = 0;
    for (samples) |s| {
        const fv = @as(f128, @floatFromInt(s));
        const dv = fv - mean;
        var_acc += dv * dv;
    }
    const stddev = std.math.sqrt(var_acc / @as(f128, samples.len));
    const cv = stddev / mean;
    var sorted: [Runs]u64 = undefined;
    for (samples, 0..) |s, idx| sorted[idx] = s;
    std.sort.heap(u64, &sorted, {}, comptime std.sort.asc(u64));
    const p95 = sorted[@min(sorted.len - 1, (sorted.len * 95) / 100)];
    std.debug.print("benchmark=snapshot_queue_depth_variance mean_ns={} cv={:.6} p95_ns={} threshold_cv=0.22 threshold_p95_ratio=2.4 max_observed={}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95, qd.sample().max });
    try std.testing.expect(cv < 0.22);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.4);
    // Ensure watermark grew (evidence of bursts)
    try std.testing.expect(qd.sample().max >= 12);
}
