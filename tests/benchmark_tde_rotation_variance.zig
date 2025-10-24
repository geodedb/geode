const std = @import("std");

// CANARY: REQ=REQ-GQL-046; FEATURE="TDE Multi-Key"; ASPECT=TDERotationVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_046_TDERotationVarianceEnvelope; OWNER=security; UPDATED=2025-09-21

fn simulateRotation(pages: usize, key_slots: usize) u64 {
    // Simulate decrypt(old)+encrypt(new) per page with key slot iteration overhead.
    var prng = std.rand.DefaultPrng.init(0x544445524F54); // 'TDEROT'
    const rand = prng.random();
    var total_ns: u64 = 0;
    var p: usize = 0;
    while (p < pages) : (p += 1) {
        const base = 1500; // 1.5µs base per page
        const jitter = rand.intRangeAtMost(u16, 0, 400); // jitter up to 400ns
        // Key slot metadata scan (~ key_slots * 30ns )
        total_ns += base + jitter + @as(u64, key_slots) * 30;
    }
    return total_ns;
}

test "BenchmarkCANARY_REQ_GQL_046_TDERotationVarianceEnvelope" {
    const Runs = 24;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const start = std.time.nanoTimestamp();
        _ = simulateRotation(4_000, 6);
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
    try std.testing.expect(cv < 0.22);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.55);
    const stderr = std.io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"tde_rotation_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
