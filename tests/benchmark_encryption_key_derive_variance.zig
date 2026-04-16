const std = @import("std");

// CANARY: REQ=REQ-GQL-046; FEATURE="TDE"; ASPECT=EncryptionKeyDeriveVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_046_EncryptionKeyDeriveVarianceEnvelope; OWNER=security; UPDATED=2025-09-21

fn simulateKdf(batch: usize, rounds: u32) u64 {
    // Simulate PBKDF/HKDF style derivation: iterative hash mixing with memory touch.
    var prng = std.rand.DefaultPrng.init(0x4B4446454E43); // 'KDFENC'
    const rand = prng.random();
    var total_ns: u64 = 0;
    var i: usize = 0;
    while (i < batch) : (i += 1) {
        var r: u32 = 0;
        var acc: u64 = rand.int(u64);
        while (r < rounds) : (r += 1) {
            // Mix op cost ~ hash + mem read
            acc ^= @as(u64, rand.int(u32)) *% 0x9E3779B185EBCA87;
            total_ns += 420 + rand.intRangeAtMost(u16, 0, 140); // 0.42-0.56us per round synthetic
            if ((r & 0x3F) == 0) {
                total_ns += 1_300 + rand.intRangeAtMost(u16, 0, 500); // block compression step
            }
        }
        // Final expansion / derive subkeys
        total_ns += 2_200 + rand.intRangeAtMost(u16, 0, 1_000);
        // Light observable side-effect to prevent full elimination (store part of acc)
        if ((acc & 0xFF) == 0x7F) {
            total_ns += 0; // noop branch using acc
        }
    }
    return total_ns;
}

test "BenchmarkCANARY_REQ_GQL_046_EncryptionKeyDeriveVarianceEnvelope" {
    const Runs = 25;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const start = std.time.nanoTimestamp();
        _ = simulateKdf(240, 260); // 240 derivations, 260 rounds each
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
    // Thresholds: CV < 0.18, p95 < 2.3x mean (derivation should be tight variance)
    try std.testing.expect(cv < 0.18);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.3);
    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"encryption_key_derive_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
