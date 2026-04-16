const std = @import("std");

// CANARY: REQ=REQ-GQL-032; FEATURE="Schema Constraints Performance"; ASPECT=UniquePerfVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_032_UniquePerfVarianceEnvelope; OWNER=schema; UPDATED=2025-09-21

fn simulateUnique(batch: usize, allocator: std.mem.Allocator) u64 {
    var map = std.AutoHashMap(u64, u8).init(allocator);
    defer map.deinit();
    var seed: u64 = 0x9e3779b97f4a7c15;
    var inserted: u64 = 0;
    var i: usize = 0;
    while (i < batch) : (i += 1) {
        // xorshift*
        seed ^= seed >> 12;
        seed ^= seed << 25;
        seed ^= seed >> 27;
        const mixed = seed *% 0x2545F4914F6CDD1D;
        // Intentionally constrain key space to induce controlled collisions
        const key = mixed & 0x00FF_FFFF; // ~16M space
        if (!map.contains(key)) {
            _ = map.put(key, 1) catch continue;
            inserted +%= 1;
        }
    }
    return inserted;
}

test "BenchmarkCANARY_REQ_GQL_032_UniquePerfVarianceEnvelope" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const Runs = 28;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const start = std.time.nanoTimestamp();
        _ = simulateUnique(3_500, allocator);
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

    try std.testing.expect(cv < 0.18);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.3);

    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"unique_perf_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
