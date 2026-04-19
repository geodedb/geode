const std = @import("std");
const schema = @import("bench_schema");
const compare = @import("compare_bench");

// Unit tests for compare-bench (M0.6).
//
// The comparator matches (scenario_name, variant, measurement) rows
// between two ResultDocuments, applies a max(15%, 3σ) noise gate, and
// dispatches higher-is-better vs lower-is-better from the measurement
// name prefix. These tests pin down each of those behaviours.

fn makeRow(measurement: []const u8, value: f64, stddev: f64) schema.ResultRow {
    return .{
        .git_sha = "a",
        .run_timestamp_unix_s = 0,
        .zig_version = "0.16",
        .os = "linux",
        .arch = "x86_64",
        .cpu = "c",
        .scenario_name = "s",
        .variant = "v",
        .measurement = measurement,
        .value = value,
        .value_stddev = stddev,
        .sample_count = 6,
        .wall_time_ns = 1000,
    };
}

test "compare returns no failure when throughput identical" {
    const allocator = std.testing.allocator;
    const row = makeRow("throughput_ops_per_sec", 1000, 10);
    var base_rows = [_]schema.ResultRow{row};
    var curr_rows = [_]schema.ResultRow{row};
    const baseline = schema.ResultDocument{ .generated_at_unix_s = 0, .rows = base_rows[0..] };
    const current = schema.ResultDocument{ .generated_at_unix_s = 1, .rows = curr_rows[0..] };
    const failures = try compare.compareDocuments(allocator, baseline, current);
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "compare flags a 20% throughput drop as regression" {
    const allocator = std.testing.allocator;
    var base_rows = [_]schema.ResultRow{makeRow("throughput_ops_per_sec", 1000, 10)};
    var curr_rows = [_]schema.ResultRow{makeRow("throughput_ops_per_sec", 800, 10)};
    const baseline = schema.ResultDocument{ .generated_at_unix_s = 0, .rows = base_rows[0..] };
    const current = schema.ResultDocument{ .generated_at_unix_s = 1, .rows = curr_rows[0..] };
    const failures = try compare.compareDocuments(allocator, baseline, current);
    try std.testing.expectEqual(@as(usize, 1), failures);
}

test "compare ignores 12% drop inside the 15% hard floor" {
    // stddev=1 on value=1000 → 3σ = 0.3%. Hard floor of 15% dominates.
    // A 12% drop must NOT fire.
    const allocator = std.testing.allocator;
    var base_rows = [_]schema.ResultRow{makeRow("throughput_ops_per_sec", 1000, 1)};
    var curr_rows = [_]schema.ResultRow{makeRow("throughput_ops_per_sec", 880, 1)};
    const baseline = schema.ResultDocument{ .generated_at_unix_s = 0, .rows = base_rows[0..] };
    const current = schema.ResultDocument{ .generated_at_unix_s = 1, .rows = curr_rows[0..] };
    const failures = try compare.compareDocuments(allocator, baseline, current);
    try std.testing.expectEqual(@as(usize, 0), failures);
}
