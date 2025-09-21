const std = @import("std");
const path_cache = @import("../src/planner/path_cache.zig");

// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheLookupVarianceEnvelope; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_021_PathCacheLookup; BENCH=BenchmarkCANARY_REQ_GQL_021_PathCacheLookupVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

pub fn main() !void {}

var seed_global: u64 = 0xdecafbad1234abcd;
fn nextRand() u64 {
    seed_global = seed_global *% 6364136223846793005 +% 1;
    return seed_global;
}

test "BenchmarkCANARY_REQ_GQL_021_PathCacheLookupVarianceEnvelope" {
    // Deterministic PRNG (LCG) for repeatability.

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var cache = try path_cache.PathCache.init(gpa.allocator(), 256);
    defer cache.deinit();

    const iterations = 10_000;
    var timings = try gpa.allocator().alloc(u64, iterations);
    defer gpa.allocator().free(timings);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Decide to use existing key or new key.
        const choose_existing = (nextRand() & 0xFF) < 180; // ~70% hit probability target
        var buf_key: [16]u8 = undefined;
        if (choose_existing and cache.statsSnapshot().misses + cache.statsSnapshot().hits > 0) {
            // Reuse a simple existing pattern: k<mod>
            const n = (nextRand() % 256);
            const written = std.fmt.formatIntBuf(&buf_key, n, 10, .lower, .{});
            const key_slice = buf_key[0..written];
            const start = std.time.nanoTimestamp();
            _ = cache.get(key_slice);
            const end = std.time.nanoTimestamp();
            timings[i] = @intCast(end - start);
        } else {
            const n = (nextRand() % 10_000);
            const written = std.fmt.formatIntBuf(&buf_key, n, 10, .lower, .{});
            const key_slice = buf_key[0..written];
            cache.put(key_slice, key_slice); // value mirrors key
            const start = std.time.nanoTimestamp();
            _ = cache.get(key_slice);
            const end = std.time.nanoTimestamp();
            timings[i] = @intCast(end - start);
        }
    }

    // Compute stats.
    var sum: f128 = 0;
    for (timings) |t| sum += @as(f128, @floatFromInt(t));
    const mean = sum / @as(f128, @floatFromInt(iterations));
    var var_acc: f128 = 0;
    for (timings) |t| {
        const diff = @as(f128, @floatFromInt(t)) - mean;
        var_acc += diff * diff;
    }
    const variance = var_acc / @as(f128, @floatFromInt(iterations));
    const stddev = std.math.sqrt(variance);
    const cv = stddev / mean;

    // p95
    std.sort.sort(u64, timings, {}, comptime std.sort.asc(u64));
    const p95_index = (iterations * 95) / 100;
    const p95 = timings[p95_index];
    const p95_mean_ratio = @as(f128, @floatFromInt(p95)) / mean;

    // Thresholds: CV ≤0.22 p95/mean ≤2.55
    if (cv > 0.22 or p95_mean_ratio > 2.55) {
        std.debug.print("VARIANCE_FAIL PathCacheLookupVarianceEnvelope mean={d:.2} stddev={d:.2} cv={d:.4} p95_ratio={d:.2}\n", .{ mean, stddev, cv, p95_mean_ratio });
        return error.VarianceExceeded;
    }
    std.debug.print("VARIANCE_OK PathCacheLookupVarianceEnvelope mean={d:.2} cv={d:.4} p95_ratio={d:.2}\n", .{ mean, cv, p95_mean_ratio });
}
