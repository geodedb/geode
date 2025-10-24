const std = @import("std");
const varcfg = @import("geode").benchmarks.variance_config;

// Basic unit tests for computeStatsF128 and thresholds
// CANARY: REQ=REQ-GQL-021; FEATURE="Bench Variance Infra"; ASPECT=VarianceConfigStats; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_VarianceConfigStats; OWNER=tooling; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_021_VarianceConfigStats" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // Known dataset: symmetric values to test mean/median/mad
    var data = [_]f128{ 10, 12, 14, 16, 18, 20, 22 };
    const stats = varcfg.computeStatsF128(allocator, data[0..]);
    try std.testing.expectApproxEqAbs(@as(f128, 16.0), stats.mean, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f128, 16.0), stats.median, 0.0001);
    // MAD: median(|x-median|) => values deviations: 6,4,2,0,2,4,6 -> sorted -> 0,2,2,4,4,6,6 median=4
    try std.testing.expectApproxEqAbs(@as(f128, 4.0), stats.mad, 0.0001);
    // p95 should be near max for small sample: index = floor(7*95/100)=6 -> 22
    try std.testing.expectApproxEqAbs(@as(f128, 22.0), stats.p95, 0.0001);
    try std.testing.expect(stats.len == data.len);
    // cv positive and p95_ratio >1
    try std.testing.expect(stats.cv > 0);
    try std.testing.expect(stats.p95_ratio > 1.0);
}

test "TestCANARY_REQ_GQL_021_VarianceConfigThresholds" {
    const redo = varcfg.thresholdsForBenchmark("redo_optimization_delta_variance");
    try std.testing.expectApproxEqAbs(@as(f128, 0.18), redo.cv_max, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f128, 1.35), redo.p95_ratio_max, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f128, 1.0), redo.min_mean, 0.0001);
    const path = varcfg.thresholdsForBenchmark("path_cache_degree_bucket_utilization_variance");
    try std.testing.expectApproxEqAbs(@as(f128, 0.22), path.cv_max, 0.0001);
    const generic = varcfg.thresholdsForBenchmark("unknown_bench_name");
    try std.testing.expectApproxEqAbs(@as(f128, 0.22), generic.cv_max, 0.0001);
}
