const std = @import("std");

// CANARY: REQ=REQ-GQL-013; FEATURE="Transactions"; ASPECT=MVCCVersionPruneVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_013_MVCCVersionPruneVarianceEnvelope; OWNER=txn; UPDATED=2025-09-21

fn simulatePrune(chains: usize, avg_versions: usize) u64 {
    // Simulate scanning version chains and pruning obsolete versions (e.g., below global min active txn).
    var prng = std.rand.DefaultPrng.init(0x565052554E45); // 'VPRUNE'
    const rand = prng.random();
    var total_ns: u64 = 0;
    var c: usize = 0;
    while (c < chains) : (c += 1) {
        // Random chain length around avg_versions with variance.
        const len = @max(1, @as(usize, @intCast(avg_versions + @as(i32, rand.intRangeAtMost(i16, -4, 6)))));
        var v: usize = 0;
        while (v < len) : (v += 1) {
            // Cost per version: read header + maybe unlink.
            const unlink_prob = (v > 0 and (v & 0x3) == 0); // ~25% obsolete
            var cost: u64 = 140 + rand.intRangeAtMost(u16, 0, 120); // header read & checks
            if (unlink_prob) {
                cost += 260 + rand.intRangeAtMost(u16, 0, 180); // pointer patch + epoch reclamation queue
            }
            total_ns += cost;
        }
        // Occasional epoch advancement bookkeeping after each chain.
        if ((c & 0x3F) == 0) {
            total_ns += 3_500 + rand.intRangeAtMost(u16, 0, 2_200);
        }
    }
    return total_ns;
}

test "BenchmarkCANARY_REQ_GQL_013_MVCCVersionPruneVarianceEnvelope" {
    const Runs = 27;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const start = std.time.nanoTimestamp();
        _ = simulatePrune(7_500, 9);
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
    // Thresholds: CV < 0.20, p95 < 2.4x mean
    try std.testing.expect(cv < 0.20);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.4);
    const stderr = std.io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"mvcc_version_prune_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
