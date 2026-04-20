const std = @import("std");
const testing = std.testing;
const common_query = @import("common_query");
const schema = @import("bench_schema");

test "QueryResultRow serializes to ResultDocument row with all phase timings" {
    const row = common_query.QueryResultRow{
        .git_sha = "deadbeef",
        .run_timestamp_unix_s = 1_700_000_000,
        .zig_version = "0.16.0",
        .os = "linux",
        .arch = "x86_64",
        .cpu = "test-cpu",
        .scenario_name = "point_read_inline",
        .variant = "default",
        .dataset_size = "small",
        .iterations = 6,
        .warmup_iterations = 1,
        .wall_time_ns_median = 1_000_000,
        .wall_time_ns_stddev = 50_000,
        .throughput_ops_per_sec = 1_000_000.0,
        .throughput_stddev_ops_per_sec = 50_000.0,
        .parse_ns_per_op_p50 = 100_000,
        .plan_ns_per_op_p50 = 200_000,
        .execute_ns_per_op_p50 = 700_000,
        .materialize_ns_per_op_p50 = 300_000,
        .row_count_p50 = 1,
        .plan_cache_hits = 5,
        .plan_cache_misses = 1,
        .alloc_count_per_op = 12,
        .alloc_bytes_per_op = 1024,
        .peak_rss_delta_bytes = 0,
    };
    const rows = try common_query.expand(testing.allocator, &[_]common_query.QueryResultRow{row});
    defer common_query.freeExpanded(testing.allocator, rows);

    // One input row expands to N generic bench_schema ResultRows — one per
    // measurement (throughput, latency p50, phase timings, alloc, rss).
    // That lets `zig build compare-bench` apply its prefix-based direction
    // rule to each measurement independently.
    try testing.expect(rows.len >= 5);
    // Spot-check: one row must have measurement = "throughput_ops_per_sec".
    var found_throughput = false;
    for (rows) |r| {
        if (std.mem.eql(u8, r.measurement, "throughput_ops_per_sec")) {
            found_throughput = true;
            try testing.expectEqual(@as(f64, 1_000_000.0), r.value);
        }
    }
    try testing.expect(found_throughput);
}

test "ScenarioSpec defaults are sensible" {
    const spec = common_query.QueryScenarioSpec{
        .name = "test",
        .query = "RETURN 1",
        .dataset_size = .small,
    };
    try testing.expectEqual(@as(usize, 7), spec.iterations);
    try testing.expectEqual(@as(usize, 1), spec.warmup_iterations);
    try testing.expectEqualStrings("default", spec.variant);
}
