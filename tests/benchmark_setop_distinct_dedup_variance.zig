const std = @import("std");

// CANARY: REQ=REQ-GQL-015; FEATURE="Set Operations"; ASPECT=SetOpDistinctDedupVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_015_SetOpDistinctDedupVarianceEnvelope; OWNER=engine; UPDATED=2025-09-21

fn simulateDistinctDedup(rows: usize, cardinality: usize) u64 {
    var prng = std.rand.DefaultPrng.init(0x5345544F50); // 'SETOP'
    const rand = prng.random();
    var map = std.AutoHashMap(u64, u8).init(std.heap.page_allocator);
    defer map.deinit();
    var i: usize = 0;
    while (i < rows) : (i += 1) {
        const v = @as(u64, rand.int(u32)) % @as(u64, cardinality);
        if (!map.contains(v)) {
            _ = map.put(v, 1) catch {}; // ignore OOM for benchmark simulation
        }
    }
    return @as(u64, @intCast(map.count()));
}

test "BenchmarkCANARY_REQ_GQL_015_SetOpDistinctDedupVarianceEnvelope" {
    const Runs = 26;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const start = std.time.nanoTimestamp();
        _ = simulateDistinctDedup(25_000, 15_000);
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
    try std.testing.expect(cv < 0.21);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.45);
    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"setop_distinct_dedup_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
