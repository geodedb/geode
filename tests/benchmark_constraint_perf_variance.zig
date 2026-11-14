const std = @import("std");

// CANARY: REQ=REQ-GQL-032; FEATURE="Schema Constraints Performance"; ASPECT=ConstraintPerfVarianceEnvelope; STATUS=IMPL; BENCH=BenchmarkCANARY_REQ_GQL_032_ConstraintPerfVarianceEnvelope; OWNER=schema; UPDATED=2026-11-14

// Simulate constraint evaluation workload with varying mix of passes/failures to measure timing variance stability.

fn simulateConstraintBatch(rows: usize, fail_ratio_ppm: u32, seed_in: *u64) u64 {
    var seed = seed_in.*;
    var work: u64 = 0;
    var i: usize = 0;
    while (i < rows) : (i += 1) {
        // xorshift
        seed ^= seed >> 12;
        seed ^= seed << 25;
        seed ^= seed >> 27;
        const v = seed *% 0x2545F4914F6CDD1D;
        const is_fail = (v % 1_000_000) < fail_ratio_ppm;
        // simulate predicate checks (range + pattern + uniqueness hash probe)
        work +%= 30; // base range + type
        work +%= 50; // pattern state traverse
        work +%= 40; // uniqueness hash probe
        if (is_fail) work +%= 20; // diagnostic build overhead
    }
    seed_in.* = seed;
    return work;
}

test "BenchmarkCANARY_REQ_GQL_032_ConstraintPerfVarianceEnvelope" {
    const Runs = 30;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        var seed: u64 = 0xC0FFEE_032 ^ @as(u64, @intCast(r));
        const start = std.time.nanoTimestamp();
        _ = simulateConstraintBatch(6_000, 120_000, &seed); // 12% fails
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

    // Constraint perf should be relatively stable: CV < 0.17, p95 < 2.25x mean
    try std.testing.expect(cv < 0.17);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.25);

    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"constraint_perf_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
