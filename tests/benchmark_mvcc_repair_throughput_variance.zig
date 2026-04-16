const std = @import("std");
const geode = @import("geode");

// CANARY: REQ=REQ-GQL-013; FEATURE="Transactions/MVCC"; ASPECT=MVCCRepairThroughputVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_013_MVCCRepairThroughputVarianceEnvelope; OWNER=txn; UPDATED=2025-09-21

// Simulates MVCC repair/cleanup pass scanning version chains and pruning obsolete versions.
// We model chains with varying lengths and random garbage ratio; measure stability of total pass time.

fn simulateChainCleanup(chain_len: usize, obsolete_ratio_ppm: u32, seed_in: *u64) u64 {
    var local_seed = seed_in.*;
    var work: u64 = 0;
    var i: usize = 0;
    while (i < chain_len) : (i += 1) {
        // xorshift64*
        local_seed ^= local_seed >> 12;
        local_seed ^= local_seed << 25;
        local_seed ^= local_seed >> 27;
        const val = local_seed *% 0x2545F4914F6CDD1D;
        const obsolete = (val % 1_000_000) < obsolete_ratio_ppm;
        // cost: read version + maybe free
        work +%= 15; // read cost constant
        if (obsolete) work +%= 45; // reclaim cost
    }
    seed_in.* = local_seed;
    return work;
}

fn simulateMvccRepair(iterations: usize) u64 {
    var seed: u64 = 0x9d34_5678_1234_abcd;
    var total: u64 = 0;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // derive parameters
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed ^= seed >> 11;
        const chain_len = 8 + (@as(usize, @intCast(seed & 0x3FF))); // 8..1031
        const obsolete_ppm = @as(u32, @intCast((seed >> 10) % 400_000)); // up to 40% obsolete
        total +%= simulateChainCleanup(chain_len, obsolete_ppm, &seed);
    }
    return total;
}

test "BenchmarkCANARY_REQ_GQL_013_MVCCRepairThroughputVarianceEnvelope" {
    const Runs = 32;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const start = std.time.nanoTimestamp();
        _ = simulateMvccRepair(7_500); // tuned for moderate runtime
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

    // Threshold: CV < 0.20, p95 < 2.4x mean (cleanup moderately variable)
    try std.testing.expect(cv < 0.20);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.4);

    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"mvcc_repair_throughput_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
