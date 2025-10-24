const std = @import("std");
const pc_mod = @import("../src/planner/path_cache.zig");

// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheEntropyStats; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_PathCacheEntropyStats; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheEntropyVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_021_PathCacheEntropyVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_021_PathCacheEntropyStats" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var cache = try pc_mod.PathCache.init(gpa.allocator(), 32);
    defer cache.deinit();
    try cache.enableDistribution(64); // 64 buckets
    // Insert patterned keys; expect non-zero entropy less than max (since distribution skewed by pattern)
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var buf: [16]u8 = undefined;
        const written = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch unreachable;
        cache.put(buf[0..written], "v");
        _ = cache.get(buf[0..written]);
    }
    const ent = cache.entropyBits();
    const norm = cache.normalizedEntropy();
    try std.testing.expect(ent > 0);
    try std.testing.expect(norm > 0 and norm <= 1.0);
}

test "BenchmarkCANARY_REQ_GQL_021_PathCacheEntropyVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var cache = try pc_mod.PathCache.init(gpa.allocator(), 128);
    defer cache.deinit();
    try cache.enableDistribution(128);
    const runs: usize = 60;
    var samples = try gpa.allocator().alloc(f64, runs);
    defer gpa.allocator().free(samples);
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        // use different insertion patterns to vary entropy slightly
        var j: usize = 0;
        while (j < 400) : (j += 1) {
            var buf: [24]u8 = undefined;
            const written = std.fmt.bufPrint(&buf, "key_{d}_{d}", .{ i, j }) catch unreachable;
            cache.put(buf[0..written], "v");
        }
        samples[i] = cache.normalizedEntropy();
    }
    var sum: f128 = 0;
    for (samples) |s| sum += s;
    const mean = sum / @as(f128, @floatFromInt(samples.len));
    var acc: f128 = 0;
    for (samples) |s| {
        const d = s - mean;
        acc += d * d;
    }
    const variance = acc / @as(f128, @floatFromInt(samples.len));
    const stddev = std.math.sqrt(variance);
    const cv = if (mean == 0) 0 else stddev / mean;
    // Sort copy for p95
    const tmp = try gpa.allocator().alloc(f64, samples.len);
    defer gpa.allocator().free(tmp);
    std.mem.copy(f64, tmp, samples);
    std.sort.pdq(f64, tmp, {}, comptime std.sort.asc(f64));
    const p95 = tmp[@min(tmp.len - 1, (tmp.len * 95) / 100)];
    const p95_ratio = p95 / mean;
    if (cv > 0.22 or p95_ratio > 2.55) return error.VarianceEnvelopeBreached;
}
