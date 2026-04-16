const std = @import("std");

// CANARY: REQ=REQ-GQL-028; FEATURE="Snapshot Compaction"; ASPECT=SnapshotCompactionVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_028_SnapshotCompactionVarianceEnvelope; OWNER=storage; UPDATED=2026-02-04

// Simulate snapshot compaction time variance: scanning records, rewriting live entries, skipping tombstones.

fn simulateSnapshotCompact(segments: usize, live_ratio_ppm: u32, seed_in: *u64) u64 {
    var seed = seed_in.*;
    var work: u64 = 0;
    var s: usize = 0;
    while (s < segments) : (s += 1) {
        seed ^= seed >> 12;
        seed ^= seed << 25;
        seed ^= seed >> 27;
        const entries = 200 + @as(usize, @intCast(seed & 0x3FF)); // 200..1211
        var e: usize = 0;
        while (e < entries) : (e += 1) {
            seed ^= seed >> 12;
            seed ^= seed << 25;
            seed ^= seed >> 27;
            const val = seed *% 0x2545F4914F6CDD1D;
            const live = (val % 1_000_000) < live_ratio_ppm;
            work +%= 25; // read + parse header
            if (live) {
                work +%= 60; // rewrite live record cost
            } else {
                work +%= 10; // skip tombstone cost
            }
        }
        // segment boundary sync
        work +%= 500;
    }
    seed_in.* = seed;
    return work;
}

test "BenchmarkCANARY_REQ_GQL_028_SnapshotCompactionVarianceEnvelope" {
    const Runs = 26;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        var seed: u64 = 0xC0DE_028 ^ @as(u64, @intCast(r));
        const start = std.time.nanoTimestamp();
        _ = simulateSnapshotCompact(18, 750_000, &seed); // 75% live density
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

    // Snapshot compaction moderately variable: CV < 0.19, p95 < 2.35x mean
    try std.testing.expect(cv < 0.19);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.35);

    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"snapshot_compaction_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
