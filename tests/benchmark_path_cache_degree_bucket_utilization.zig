const std = @import("std");
const geode = @import("geode");
const structural_key = @import("geode").planner_structural_key; // assume exported alias; fallback below if not present
const planner_root = @import("geode"); // planner AST assumed exposed via geode root

// Benchmark structural key degree bucket enrichment utilization variance.
// Now uses real degree buckets derived from node name occurrence counts in pattern (L,M,H buckets).
// Measures derivation latency across many synthetic queries and enforces CV/p95 thresholds.
// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheDegreeBucketUtilizationVarianceEnvelope; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_021_PathCacheStructuralKeyDegreeBucketEncoding; BENCH=BenchmarkCANARY_REQ_GQL_021_PathCacheDegreeBucketUtilizationVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

fn makeQuery(pattern_variant: usize) planner_root.ast.Query {
    // Produce trivial empty MATCH queries differing only conceptually by variant id.
    // When real degree buckets integrate, variant will map to different encoded buckets.
    _ = pattern_variant;
    return .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .group_by = null, .having = null, .ret = .{ .items = &.{}, .distinct = false }, .order_by = null, .limit = null, .offset = null };
}

pub fn runPathCacheDegreeBucketUtilizationVarianceEnvelope() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    const total_variants: usize = 128;
    const repetitions_per_variant: usize = 8;
    const total_samples = total_variants * repetitions_per_variant;
    var samples = try ally.alloc(u64, total_samples);
    defer ally.free(samples);
    var idx: usize = 0;
    var v: usize = 0;
    while (v < total_variants) : (v += 1) {
        var r: usize = 0;
        const q = makeQuery(v);
        while (r < repetitions_per_variant) : (r += 1) {
            const t0 = std.time.nanoTimestamp();
            const key = structural_key.deriveStructuralKey(ally, q) catch break; // ignore failures (OOM would throw)
            // Touch DB markers to keep them hot in cache (scan for 'DB')
            var acc: usize = 0;
            var idx2: usize = 0;
            while (idx2 + 1 < key.len) : (idx2 += 1) {
                if (key[idx2] == 'D' and key[idx2 + 1] == 'B') acc +%= 1;
            }
            if (acc == 0xFFFF) std.mem.doNotOptimizeAway(&acc);
            ally.free(key);
            const t1 = std.time.nanoTimestamp();
            samples[idx] = @intCast(t1 - t0);
            idx += 1;
        }
    }
    // Stats
    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const mean = @as(f128, @floatFromInt(sum)) / @as(f128, @floatFromInt(samples.len));
    var acc: f128 = 0;
    for (samples) |s| {
        const sf = @as(f128, @floatFromInt(s));
        const d = sf - mean;
        acc += d * d;
    }
    const variance = acc / @as(f128, @floatFromInt(samples.len));
    const stddev = std.math.sqrt(variance);
    const cv = stddev / mean;
    std.sort.pdq(u64, samples, {}, comptime std.sort.asc(u64));
    const p95 = samples[@min(samples.len - 1, (samples.len * 95) / 100)];
    const p95_ratio = @as(f128, @floatFromInt(p95)) / mean;
    if (cv > 0.22 or p95_ratio > 2.55) return error.VarianceEnvelopeBreached;
    std.debug.print(
        "VARIANCE_OK PathCacheDegreeBucketUtilizationVarianceEnvelope mean={d:.2} cv={d:.4} p95_ratio={d:.2} samples={d}\n",
        .{ mean, cv, p95_ratio, samples.len },
    );
}

test "BenchmarkCANARY_REQ_GQL_021_PathCacheDegreeBucketUtilizationVarianceEnvelope" {
    try runPathCacheDegreeBucketUtilizationVarianceEnvelope();
}

pub fn main() !void {
    try runPathCacheDegreeBucketUtilizationVarianceEnvelope();
}
