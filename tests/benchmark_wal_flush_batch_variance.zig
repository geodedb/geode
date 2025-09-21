const std = @import("std");

// CANARY: REQ=REQ-GQL-028; FEATURE="WAL Flush Batch"; ASPECT=WALFlushBatchVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_028_WALFlushBatchVarianceEnvelope; OWNER=storage; UPDATED=2025-09-21

fn simulateFlushBatch(batch: usize, page_size: usize) u64 {
    // Simulate grouping log records into flush batches with variable record sizes.
    var prng = std.rand.DefaultPrng.init(0xCAFEBABE1234); // deterministic seed
    const rand = prng.random();
    var used: usize = 0;
    var flushes: u64 = 0;
    var i: usize = 0;
    while (i < batch) : (i += 1) {
        const rec = 32 + @as(usize, @intCast(rand.intRangeAtMost(u16, 0, 224))); // 32..256 bytes
        if (used + rec > page_size) {
            flushes += 1;
            used = 0;
        }
        used += rec;
    }
    if (used > 0) flushes += 1;
    // Model flush latency ~ base + jitter per flush
    var total_ns: u64 = 0;
    var f: u64 = 0;
    while (f < flushes) : (f += 1) {
        const jitter = rand.intRangeAtMost(u16, 0, 300); // up to 300ns jitter
        total_ns += 2200 + jitter; // base 2.2µs synthetic flush
    }
    return total_ns;
}

test "BenchmarkCANARY_REQ_GQL_028_WALFlushBatchVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const Runs = 30;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const start = std.time.nanoTimestamp();
        _ = simulateFlushBatch(8_000, 4096);
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
    try std.testing.expect(cv < 0.20);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.4);
    const stderr = std.io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"wal_flush_batch_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
