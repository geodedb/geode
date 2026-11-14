const std = @import("std");

// CANARY: REQ=REQ-GQL-028; FEATURE="Snapshot Flush Batch"; ASPECT=SnapshotFlushBatchVarianceEnvelope; STATUS=IMPL; BENCH=BenchmarkCANARY_REQ_GQL_028_SnapshotFlushBatchVarianceEnvelope; OWNER=storage; UPDATED=2026-11-14

inline fn lcgNext(seed_ptr: *u64) u32 {
    seed_ptr.* = seed_ptr.* * 6364136223846793005 + 1;
    return @intCast((seed_ptr.* >> 32) & 0xFFFFFFFF);
}

fn simulateFlushBatch(batch: usize, page_size: usize) u64 {
    // Deterministic pseudo-random generator (LCG) to avoid std.rand dependency differences.
    var seed: u64 = 0xCAFEBABE1234;
    var used: usize = 0;
    var flushes: u64 = 0;
    var i: usize = 0;
    while (i < batch) : (i += 1) {
        const r = lcgNext(&seed);
        const rec = 32 + (r % 225); // 32..256 bytes
        if (used + rec > page_size) {
            flushes += 1;
            used = 0;
        }
        used += rec;
    }
    if (used > 0) flushes += 1;
    var total_ns: u64 = 0;
    var f: u64 = 0;
    while (f < flushes) : (f += 1) {
        const jitter = lcgNext(&seed) % 301; // up to 300ns
        total_ns += 2200 + jitter;
    }
    return total_ns;
}

test "BenchmarkCANARY_REQ_GQL_028_SnapshotFlushBatchVarianceEnvelope" {
    var gpa = std.heap.DebugAllocator(.{}){};
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
    std.debug.print("benchmark=snapshot_flush_batch_variance mean_ns={} cv={:.4} p95_ns={}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
