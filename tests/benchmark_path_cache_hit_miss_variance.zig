const std = @import("std");
const path_cache = @import("../src/planner/path_cache.zig");

// Benchmark comparing hit vs miss lookup latency distributions.
// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheHitMissVarianceEnvelope; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_021_PathCacheLookup; BENCH=BenchmarkCANARY_REQ_GQL_021_PathCacheHitMissVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

var seed_hm: u64 = 0x0123_4567_89ab_cdef;
fn nextRand() u64 {
    seed_hm = seed_hm *% 6364136223846793005 +% 1;
    return seed_hm;
}

test "BenchmarkCANARY_REQ_GQL_021_PathCacheHitMissVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var cache = try path_cache.PathCache.init(gpa.allocator(), 512);
    defer cache.deinit();

    // Pre-populate with 256 entries for hits.
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        var buf: [16]u8 = undefined;
        const written = std.fmt.formatIntBuf(&buf, i, 10, .lower, .{});
        cache.put(buf[0..written], buf[0..written]);
    }

    const iterations = 6_000;
    var hit_times = try gpa.allocator().alloc(u64, iterations);
    defer gpa.allocator().free(hit_times);
    var miss_times = try gpa.allocator().alloc(u64, iterations);
    defer gpa.allocator().free(miss_times);

    var hcount: usize = 0;
    var mcount: usize = 0;
    while (hcount < iterations or mcount < iterations) {
        const choose_hit = (nextRand() & 1) == 0;
        if (choose_hit and hcount < iterations) {
            const idx = nextRand() % 256;
            var buf: [16]u8 = undefined;
            const written = std.fmt.formatIntBuf(&buf, idx, 10, .lower, .{});
            const key = buf[0..written];
            const start = std.time.nanoTimestamp();
            _ = cache.get(key);
            const end = std.time.nanoTimestamp();
            hit_times[hcount] = @intCast(end - start);
            hcount += 1;
        } else if (!choose_hit and mcount < iterations) {
            // Miss: generate key not in [0,255] range
            const idx = 10_000 + (nextRand() % 20_000);
            var buf: [16]u8 = undefined;
            const written = std.fmt.formatIntBuf(&buf, idx, 10, .lower, .{});
            const key = buf[0..written];
            const start = std.time.nanoTimestamp();
            _ = cache.get(key); // remains miss, we do not insert
            const end = std.time.nanoTimestamp();
            miss_times[mcount] = @intCast(end - start);
            mcount += 1;
        }
    }

    const mean_hit = computeMean(hit_times);
    const mean_miss = computeMean(miss_times);
    const cv_hit, const p95_ratio_hit = computeStats(hit_times);
    const cv_miss, const p95_ratio_miss = computeStats(miss_times);

    // Expectations: hits faster or equal; each distribution within thresholds.
    if (mean_hit > mean_miss) return error.HitSlowerThanMiss;
    if (cv_hit > 0.22 or p95_ratio_hit > 2.55) return error.VarianceExceededHits;
    if (cv_miss > 0.22 or p95_ratio_miss > 2.55) return error.VarianceExceededMisses;
    std.debug.print(
        "VARIANCE_OK PathCacheHitMissVarianceEnvelope mean_hit={d:.2} mean_miss={d:.2} cv_hit={d:.4} cv_miss={d:.4} p95h={d:.2} p95m={d:.2}\n",
        .{ mean_hit, mean_miss, cv_hit, cv_miss, p95_ratio_hit, p95_ratio_miss },
    );
}

fn computeMean(data: []const u64) f128 {
    var sum: f128 = 0;
    for (data) |v| sum += @as(f128, @floatFromInt(v));
    return sum / @as(f128, @floatFromInt(data.len));
}

fn computeStats(data: []const u64) struct { f128, f128 } {
    const mean = computeMean(data);
    var var_acc: f128 = 0;
    for (data) |v| {
        const diff = @as(f128, @floatFromInt(v)) - mean;
        var_acc += diff * diff;
    }
    const variance = var_acc / @as(f128, @floatFromInt(data.len));
    const stddev = std.math.sqrt(variance);
    const cv = stddev / mean;
    // p95 (copy to scratch to avoid mutating original slice for potential reuse)
    const scratch = std.heap.page_allocator.alloc(u64, data.len) catch return .{ cv, 0 };
    defer std.heap.page_allocator.free(scratch);
    @memcpy(scratch, data);
    std.sort.sort(u64, scratch, {}, comptime std.sort.asc(u64));
    const p95_index = (data.len * 95) / 100;
    const p95 = scratch[p95_index];
    const p95_ratio = @as(f128, @floatFromInt(p95)) / mean;
    return .{ cv, p95_ratio };
}
