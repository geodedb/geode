const std = @import("std");
const geode = @import("geode");
const gpu_mod = geode.gpu.flagger;

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=GPUFlaggerEnumerationVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_051_GPUFlaggerEnumerationVarianceEnvelope; OWNER=exec; UPDATED=2025-09-21

fn simulateEnumeration(iterations: usize) u64 {
    var work: u64 = 0;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Enumeration currently always reports unsupported; simulate stable path.
        const st = gpu_mod.status();
        if (st.accel_supported) {
            work +%= 100; // would reflect device queries
        } else {
            work +%= 30; // unsupported cheap path
        }
    }
    return work;
}

test "BenchmarkCANARY_REQ_GQL_051_GPUFlaggerEnumerationVarianceEnvelope" {
    const Runs = 28;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const start = std.time.nanoTimestamp();
        _ = simulateEnumeration(150_000);
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

    // Enumeration path should be quite stable (no real device IO yet): CV < 0.18, p95 < 2.3x mean
    try std.testing.expect(cv < 0.18);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.3);

    const stderr = std.io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"gpu_flagger_enumeration_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
