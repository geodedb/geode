// Thin compatibility wrapper -- delegates to the external timeseries library
// while preserving the public API surface used by Geode consumers.
//
// Upstream: @import("timeseries_lib")  (geode/build.zig wires this)

// CANARY: REQ=REQ-TS-STORE-001; FEATURE="TimeSeriesStore"; ASPECT=Core; STATUS=TESTED; TEST=src/timeseries/timeseries.zig:"ts: insert/order/last/asof"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-INSERT-001; FEATURE="TimeSeriesInsertMany"; ASPECT=DataIngestion; STATUS=TESTED; TEST=src/timeseries/timeseries.zig:"ts: insert/order/last/asof"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-LAST-001; FEATURE="TimeSeriesLast"; ASPECT=Query; STATUS=TESTED; TEST=src/timeseries/timeseries.zig:"ts: insert/order/last/asof"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-VALUEBEFORE-001; FEATURE="TimeSeriesValueBefore"; ASPECT=Query; STATUS=TESTED; TEST=src/timeseries/timeseries.zig:"ts: insert/order/last/asof"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-SAMPLEBY-001; FEATURE="TimeSeriesSampleBy"; ASPECT=Aggregation; STATUS=TESTED; TEST=src/timeseries/timeseries.zig:"ts: sampleBy aggregations"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-TIMEBUCKET-001; FEATURE="TimeSeriesTimeBucketAvg"; ASPECT=Aggregation; STATUS=TESTED; TEST=src/timeseries/timeseries.zig:"ts: timeBucketAvg basic"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-VALUEAT-001; FEATURE="TimeSeriesValueAt"; ASPECT=Query; STATUS=TESTED; TEST=src/timeseries/timeseries.zig:"ts: valueAt and lastValue"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-SERIESKEY-001; FEATURE="TimeSeriesSeriesKey"; ASPECT=Types; STATUS=TESTED; TEST=src/timeseries/timeseries.zig:"ts: insert/order/last/asof"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-POINT-001; FEATURE="TimeSeriesPoint"; ASPECT=Types; STATUS=TESTED; TEST=src/timeseries/timeseries.zig:"ts: insert/order/last/asof"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-PERSIST-001; FEATURE="TimeSeriesPersistence"; ASPECT=StoreConfig; STATUS=IMPL; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-PERSIST-002; FEATURE="TimeSeriesLoadFromDisk"; ASPECT=Startup; STATUS=IMPL; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-PERSIST-003; FEATURE="TimeSeriesSync"; ASPECT=Shutdown; STATUS=IMPL; OWNER=timeseries; UPDATED=2026-04-01

const ts_lib = @import("timeseries_lib");

// Re-export core store types at the same names the rest of Geode expects.
pub const Point = ts_lib.Point;
pub const PointF64 = ts_lib.PointF64;
pub const SeriesKey = ts_lib.SeriesKey;
pub const Series = ts_lib.Series;
pub const Store = ts_lib.Store;
pub const StoreConfig = ts_lib.StoreConfig;
pub const ChunkConfig = ts_lib.ChunkConfig;
pub const ChunkStorage = ts_lib.ChunkStorage;

// Re-export the external library's full namespace so advanced consumers
// (e.g. DTW, matrix profile, features) can reach sub-modules.
pub const lib = ts_lib;

// ---------------------------------------------------------------------------
// Tests -- verify that the external library types work through this wrapper.
// ---------------------------------------------------------------------------

const std = @import("std");

test "ts: insert/order/last/asof" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();
    const key = SeriesKey{ .device_id = 1, .metric = "temp" };
    try st.insertMany(key, &.{ .{ .ts = 100, .value = 10 }, .{ .ts = 90, .value = 9 }, .{ .ts = 110, .value = 11 } });
    const l = st.last(key).?;
    try std.testing.expect(l.ts == 110 and l.value == 11);
    const p = st.valueBefore(key, 105).?;
    try std.testing.expect(p.ts == 100 and p.value == 10);
}

test "ts: timeBucketAvg basic" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();
    const key = SeriesKey{ .device_id = 1, .metric = "temp" };
    try st.insertMany(key, &.{ .{ .ts = 0, .value = 10 }, .{ .ts = 5, .value = 20 }, .{ .ts = 10, .value = 30 } });
    const out = try st.timeBucketAvg(key, 10, 0, 20, allocator);
    defer allocator.free(out);
    try std.testing.expect(out.len == 2);
    try std.testing.expect(out[0].ts == 0 and out[0].avg.? == 15);
    try std.testing.expect(out[1].ts == 10 and out[1].avg.? == 30);
}

test "ts: sampleBy aggregations" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 1, .metric = "cpu" };
    try st.insertMany(key, &.{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
        .{ .ts = 11000, .value = 40 },
        .{ .ts = 12000, .value = 50 },
    });

    // Test AVG aggregation
    const avg_result = try st.sampleBy(key, 10000, 0, 20000, .avg, allocator);
    defer allocator.free(avg_result);
    try std.testing.expect(avg_result.len == 2);
    try std.testing.expect(avg_result[0].value.? == 20); // avg of 10,20,30
    try std.testing.expect(avg_result[1].value.? == 45); // avg of 40,50

    // Test MIN aggregation
    const min_result = try st.sampleBy(key, 10000, 0, 20000, .min, allocator);
    defer allocator.free(min_result);
    try std.testing.expect(min_result[0].value.? == 10);
    try std.testing.expect(min_result[1].value.? == 40);

    // Test MAX aggregation
    const max_result = try st.sampleBy(key, 10000, 0, 20000, .max, allocator);
    defer allocator.free(max_result);
    try std.testing.expect(max_result[0].value.? == 30);
    try std.testing.expect(max_result[1].value.? == 50);

    // Test COUNT aggregation
    const count_result = try st.sampleBy(key, 10000, 0, 20000, .count, allocator);
    defer allocator.free(count_result);
    try std.testing.expect(count_result[0].value.? == 3);
    try std.testing.expect(count_result[1].value.? == 2);
}

test "ts: valueAt and lastValue" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 1, .metric = "memory" };
    try st.insertMany(key, &.{
        .{ .ts = 1000, .value = 100 },
        .{ .ts = 2000, .value = 200 },
        .{ .ts = 3000, .value = 300 },
    });

    // Test lastValue
    const last = st.last(key).?;
    try std.testing.expect(last.ts == 3000 and last.value == 300);

    // Test valueAt (exact match)
    const hk = st.hashKey(key);
    const series = st.by_key.get(hk).?;
    const exact = series.valueAt(2000).?;
    try std.testing.expect(exact.ts == 2000 and exact.value == 200);

    // Test valueAt (interpolated/closest)
    const closest = series.valueAt(2500).?;
    try std.testing.expect(closest.ts == 2000 and closest.value == 200);
}

// ---------------------------------------------------------------------------
// GAP-0284: SUM/FIRST/LAST aggregation tests
// ---------------------------------------------------------------------------

test "ts: sampleBy SUM aggregation" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 2, .metric = "bytes" };
    try st.insertMany(key, &.{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
        .{ .ts = 11000, .value = 40 },
        .{ .ts = 12000, .value = 50 },
    });

    const result = try st.sampleBy(key, 10000, 0, 20000, .sum, allocator);
    defer allocator.free(result);

    // Bucket [0, 10000): points 10+20+30 = 60
    // Bucket [10000, 20000): points 40+50 = 90
    try std.testing.expect(result.len == 2);
    try std.testing.expectEqual(@as(i64, 60), result[0].value.?);
    try std.testing.expectEqual(@as(i64, 90), result[1].value.?);
}

test "ts: sampleBy FIRST aggregation" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 2, .metric = "bytes" };
    try st.insertMany(key, &.{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
        .{ .ts = 11000, .value = 40 },
        .{ .ts = 12000, .value = 50 },
    });

    const result = try st.sampleBy(key, 10000, 0, 20000, .first, allocator);
    defer allocator.free(result);

    // Bucket [0, 10000): first point value = 10
    // Bucket [10000, 20000): first point value = 40
    try std.testing.expect(result.len == 2);
    try std.testing.expectEqual(@as(i64, 10), result[0].value.?);
    try std.testing.expectEqual(@as(i64, 40), result[1].value.?);
}

test "ts: sampleBy LAST aggregation" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 2, .metric = "bytes" };
    try st.insertMany(key, &.{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
        .{ .ts = 11000, .value = 40 },
        .{ .ts = 12000, .value = 50 },
    });

    const result = try st.sampleBy(key, 10000, 0, 20000, .last, allocator);
    defer allocator.free(result);

    // Bucket [0, 10000): last point value = 30
    // Bucket [10000, 20000): last point value = 50
    try std.testing.expect(result.len == 2);
    try std.testing.expectEqual(@as(i64, 30), result[0].value.?);
    try std.testing.expectEqual(@as(i64, 50), result[1].value.?);
}

test "ts: sampleBy SUM/FIRST/LAST with empty bucket" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 3, .metric = "gap" };
    // Points only in first bucket, second bucket empty
    try st.insertMany(key, &.{
        .{ .ts = 100, .value = 5 },
        .{ .ts = 200, .value = 15 },
    });

    const sum_result = try st.sampleBy(key, 1000, 0, 2000, .sum, allocator);
    defer allocator.free(sum_result);
    try std.testing.expect(sum_result.len == 2);
    try std.testing.expectEqual(@as(i64, 20), sum_result[0].value.?);
    try std.testing.expect(sum_result[1].value == null); // empty bucket

    const first_result = try st.sampleBy(key, 1000, 0, 2000, .first, allocator);
    defer allocator.free(first_result);
    try std.testing.expectEqual(@as(i64, 5), first_result[0].value.?);
    try std.testing.expect(first_result[1].value == null);

    const last_result = try st.sampleBy(key, 1000, 0, 2000, .last, allocator);
    defer allocator.free(last_result);
    try std.testing.expectEqual(@as(i64, 15), last_result[0].value.?);
    try std.testing.expect(last_result[1].value == null);
}

// ---------------------------------------------------------------------------
// GAP-0285: valueAt and timeBucketAvg dedicated tests
// ---------------------------------------------------------------------------

test "ts: valueAt — before first timestamp returns null" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 4, .metric = "val" };
    try st.insertMany(key, &.{
        .{ .ts = 5000, .value = 50 },
        .{ .ts = 6000, .value = 60 },
    });

    const hk = st.hashKey(key);
    const series = st.by_key.get(hk).?;

    // Timestamp before all points — binary search finds nothing before
    const result = series.valueAt(1000);
    try std.testing.expect(result == null);
}

test "ts: valueAt — after last timestamp returns last-before point" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 4, .metric = "val" };
    try st.insertMany(key, &.{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
    });

    const hk = st.hashKey(key);
    const series = st.by_key.get(hk).?;

    // Timestamp after all points — returns last point (closest before)
    const result = series.valueAt(9999).?;
    try std.testing.expectEqual(@as(i64, 3000), result.ts);
    try std.testing.expectEqual(@as(i64, 30), result.value);
}

test "ts: valueAt — exact match returns exact point" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 4, .metric = "val" };
    try st.insertMany(key, &.{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
    });

    const hk = st.hashKey(key);
    const series = st.by_key.get(hk).?;

    // Exact match on first, middle, and last
    const first = series.valueAt(1000).?;
    try std.testing.expectEqual(@as(i64, 1000), first.ts);
    try std.testing.expectEqual(@as(i64, 10), first.value);

    const mid = series.valueAt(2000).?;
    try std.testing.expectEqual(@as(i64, 2000), mid.ts);
    try std.testing.expectEqual(@as(i64, 20), mid.value);

    const end = series.valueAt(3000).?;
    try std.testing.expectEqual(@as(i64, 3000), end.ts);
    try std.testing.expectEqual(@as(i64, 30), end.value);
}

test "ts: valueAt — empty series returns null" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 5, .metric = "empty" };
    // Insert zero points — getOrCreateSeries creates the series
    try st.insertMany(key, &.{});

    const hk = st.hashKey(key);
    const series = st.by_key.get(hk).?;
    const result = series.valueAt(1000);
    try std.testing.expect(result == null);
}

test "ts: timeBucketAvg — empty range returns empty" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 6, .metric = "empty_range" };
    try st.insertMany(key, &.{
        .{ .ts = 100, .value = 10 },
    });

    // end <= start → should return empty slice
    const result = try st.timeBucketAvg(key, 10, 100, 100, allocator);
    try std.testing.expectEqual(@as(usize, 0), result.len);

    // Also test reversed range
    const result2 = try st.timeBucketAvg(key, 10, 200, 100, allocator);
    try std.testing.expectEqual(@as(usize, 0), result2.len);
}

test "ts: timeBucketAvg — single-point bucket" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 6, .metric = "single" };
    try st.insertMany(key, &.{
        .{ .ts = 5, .value = 42 },
    });

    // One bucket [0, 10) containing one point with value 42
    const result = try st.timeBucketAvg(key, 10, 0, 10, allocator);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(i64, 0), result[0].ts);
    try std.testing.expectEqual(@as(i64, 42), result[0].avg.?);
}

test "ts: timeBucketAvg — bucket with no points returns null avg" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 6, .metric = "sparse" };
    try st.insertMany(key, &.{
        .{ .ts = 5, .value = 100 },
        // gap: no points in [10, 20)
        .{ .ts = 25, .value = 200 },
    });

    const result = try st.timeBucketAvg(key, 10, 0, 30, allocator);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(@as(i64, 100), result[0].avg.?); // bucket [0,10)
    try std.testing.expect(result[1].avg == null); // bucket [10,20) — empty
    try std.testing.expectEqual(@as(i64, 200), result[2].avg.?); // bucket [20,30)
}

test "ts: timeBucketAvg — boundary: point exactly at bucket start" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 6, .metric = "boundary" };
    try st.insertMany(key, &.{
        .{ .ts = 0, .value = 10 },
        .{ .ts = 10, .value = 20 },
        .{ .ts = 20, .value = 30 },
    });

    // Buckets: [0,10), [10,20), [20,30)
    // ts=0 in bucket 0, ts=10 in bucket 1, ts=20 in bucket 2
    const result = try st.timeBucketAvg(key, 10, 0, 30, allocator);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(@as(i64, 10), result[0].avg.?);
    try std.testing.expectEqual(@as(i64, 20), result[1].avg.?);
    try std.testing.expectEqual(@as(i64, 30), result[2].avg.?);
}

// ---------------------------------------------------------------------------
// GAP-0292: Persistence round-trip test via wrapper
// ---------------------------------------------------------------------------

test "ts: persist-restart-query via StoreConfig" {
    const allocator = std.testing.allocator;

    const pid = if (@import("builtin").os.tag == .linux) std.os.linux.getpid() else 0;
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/geode_ts_persist_{d}", .{pid}) catch unreachable;
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const key = SeriesKey{ .device_id = 7, .metric = "voltage" };

    // Phase 1: insert and deinit (flush to disk).
    {
        var st = try Store.initWithConfig(allocator, .{
            .data_dir = test_dir,
            .chunk_config = .{ .max_points_per_chunk = 10 },
        });
        defer st.deinit();

        try st.insertMany(key, &.{
            .{ .ts = 100, .value = 220 },
            .{ .ts = 200, .value = 221 },
            .{ .ts = 300, .value = 219 },
        });
    }

    // Phase 2: reload and verify.
    {
        var st2 = try Store.initWithConfig(allocator, .{
            .data_dir = test_dir,
            .chunk_config = .{ .max_points_per_chunk = 10 },
        });
        defer st2.deinit();

        try st2.loadFromDisk();

        const last = st2.last(key);
        try std.testing.expect(last != null);
        try std.testing.expectEqual(@as(i64, 300), last.?.ts);
        try std.testing.expectEqual(@as(i64, 219), last.?.value);
    }
}

test "ts: StoreConfig re-export available" {
    // Verify that StoreConfig, ChunkConfig, ChunkStorage are accessible through the wrapper.
    const cfg = StoreConfig{ .data_dir = null };
    try std.testing.expect(cfg.data_dir == null);
    const cc = ChunkConfig{};
    try std.testing.expect(cc.retention_days == 30);
}
