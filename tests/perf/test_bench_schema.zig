const std = @import("std");
const schema = @import("bench_schema");

// Verifies the stable JSON schema emitted by perf benches (M0.4).
// Contract: the downstream compare-bench comparator (M0.6) and
// scripts/perf-gate.sh (M0.7) read these field names verbatim — do not
// rename ResultRow fields without updating both consumers.

test "ResultRow serialises to stable JSON with required fields" {
    const allocator = std.testing.allocator;
    const row = schema.ResultRow{
        .git_sha = "deadbeef",
        .run_timestamp_unix_s = 1_700_000_000,
        .zig_version = "0.16.0",
        .os = "linux",
        .arch = "x86_64",
        .cpu = "test-cpu",
        .scenario_name = "timeseries_ingest_1m",
        .variant = "default",
        .measurement = "throughput_points_per_sec",
        .value = 86_700_000.0,
        .value_stddev = 1_000_000.0,
        .sample_count = 6,
        .wall_time_ns = 11_530_000,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, row, .{});
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenario_name\":\"timeseries_ingest_1m\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"measurement\":\"throughput_points_per_sec\"") != null);
    // Float formatting may vary across Zig versions (8.67e7 vs 86700000);
    // assert the exponent OR the decimal form, whichever the stdlib emits.
    const has_exp = std.mem.indexOf(u8, json, "8.67e7") != null;
    const has_dec = std.mem.indexOf(u8, json, "86700000") != null;
    try std.testing.expect(has_exp or has_dec);
    // Integer and field presence sanity checks.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sample_count\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"git_sha\":\"deadbeef\"") != null);
}

test "ResultDocument round-trips through writeDocument/readDocument" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var rows = [_]schema.ResultRow{
        .{
            .git_sha = "abc123",
            .run_timestamp_unix_s = 1_700_000_100,
            .zig_version = "0.16.0",
            .os = "linux",
            .arch = "x86_64",
            .cpu = "test-cpu",
            .scenario_name = "timeseries_ingest_100k",
            .measurement = "throughput_points_per_sec",
            .value = 12_345_678.0,
            .sample_count = 6,
            .wall_time_ns = 500_000,
        },
    };
    const doc = schema.ResultDocument{
        .generated_at_unix_s = 1_700_000_200,
        .rows = rows[0..],
    };

    // Write to cwd — the test runner always has a writable working
    // directory. Use a distinctive name so a failed cleanup doesn't
    // collide with anything else.
    const path = "bench_schema_roundtrip.test.json";
    try schema.writeDocument(allocator, io, path, doc);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var parsed = try schema.readDocument(allocator, io, path);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.rows.len);
    try std.testing.expectEqualStrings("timeseries_ingest_100k", parsed.value.rows[0].scenario_name);
    try std.testing.expectEqual(@as(i64, 1_700_000_200), parsed.value.generated_at_unix_s);
}
