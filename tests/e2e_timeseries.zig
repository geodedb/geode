const std = @import("std");
const timeseries_lib = @import("timeseries_lib");
const timeseries = timeseries_lib;
const chunk_storage = timeseries_lib.chunk_storage;
const gql_functions = @import("gql_functions");

test "e2e_timeseries: basic store operations" {
    const allocator = std.testing.allocator;

    var store = timeseries.Store.init(allocator);
    defer store.deinit();

    // Insert data for multiple series
    const temp_key = timeseries.SeriesKey{ .device_id = 1, .metric = "temperature" };
    const humidity_key = timeseries.SeriesKey{ .device_id = 1, .metric = "humidity" };

    // Generate realistic time-series data
    var temp_points: std.ArrayList(timeseries.Point) = .{};
    defer temp_points.deinit(allocator);
    var humidity_points: std.ArrayList(timeseries.Point) = .{};
    defer humidity_points.deinit(allocator);

    var i: i64 = 0;
    while (i < 100) : (i += 1) {
        const ts = 1000000 + i * 1000; // 1 second intervals

        // Temperature varies between 20-25 C
        const temp_value = 20 + @mod(i * 7, 5);
        try temp_points.append(allocator, .{ .ts = ts, .value = temp_value });

        // Humidity varies between 40-60%
        const humidity_value = 40 + @mod(i * 13, 20);
        try humidity_points.append(allocator, .{ .ts = ts, .value = humidity_value });
    }

    try store.insertMany(temp_key, temp_points.items);
    try store.insertMany(humidity_key, humidity_points.items);

    // Test last_value
    const last_temp = store.last(temp_key).?;
    try std.testing.expect(last_temp.ts == 1099000);

    const last_humidity = store.last(humidity_key).?;
    try std.testing.expect(last_humidity.ts == 1099000);

    // Test value_at (with interpolation)
    const temp_at_50s = store.valueBefore(temp_key, 1050500).?; // Between 50th and 51st second
    try std.testing.expect(temp_at_50s.ts == 1050000);

    // Test sample_by with different aggregations
    const avg_samples = try store.sampleBy(temp_key, 10000, // 10 second buckets
        1000000, 1100000, .avg, allocator);
    defer allocator.free(avg_samples);

    try std.testing.expect(avg_samples.len == 10);
    for (avg_samples) |sample| {
        try std.testing.expect(sample.value != null);
        try std.testing.expect(sample.value.? >= 20 and sample.value.? <= 25);
    }

    // Test min/max aggregations
    const min_samples = try store.sampleBy(humidity_key, 20000, // 20 second buckets
        1000000, 1100000, .min, allocator);
    defer allocator.free(min_samples);

    const max_samples = try store.sampleBy(humidity_key, 20000, 1000000, 1100000, .max, allocator);
    defer allocator.free(max_samples);

    try std.testing.expect(min_samples.len == 5);
    try std.testing.expect(max_samples.len == 5);

    // Verify min <= max for each bucket
    for (min_samples, max_samples) |min_sample, max_sample| {
        try std.testing.expect(min_sample.ts == max_sample.ts);
        if (min_sample.value != null and max_sample.value != null) {
            try std.testing.expect(min_sample.value.? <= max_sample.value.?);
        }
    }
}

test "e2e_timeseries: chunk storage with compression" {
    const allocator = std.testing.allocator;

    const pid = std.os.linux.getpid();
    var dir_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&dir_buf, "/tmp/test_timeseries_chunks_{d}", .{pid}) catch unreachable;
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var storage = try chunk_storage.ChunkStorage.init(allocator, test_dir, .{
        .max_points_per_chunk = 1000,
        .compression_algorithm = .gorilla,
        .retention_days = 7,
    });
    defer storage.deinit();

    // Generate high-frequency time-series data
    var points: std.ArrayList(timeseries.Point) = .{};
    defer points.deinit(allocator);

    // Simulate 1 hour of data at 10Hz (36,000 points)
    var t: i64 = 0;
    while (t < 3600) : (t += 1) {
        var hz: i64 = 0;
        while (hz < 10) : (hz += 1) {
            const ts = 1000000000 + t * 1000 + hz * 100;
            // Sine wave pattern for realistic sensor data
            const angle = @as(f64, @floatFromInt(t * 10 + hz)) * std.math.pi / 180.0;
            const value = @as(i64, @intFromFloat(1000.0 + 100.0 * @sin(angle)));
            try points.append(allocator, .{ .ts = ts, .value = value });
        }
    }

    // Write in batches to simulate real-world ingestion
    const batch_size = 1000;
    var written: usize = 0;
    while (written < points.items.len) {
        const end = @min(written + batch_size, points.items.len);
        const batch = points.items[written..end];
        try storage.writePoints(42, batch);
        written = end;
    }

    // Check compression statistics
    const stats = storage.getCompressionStats();
    try std.testing.expect(stats.total_chunks > 0);
    try std.testing.expect(stats.ratio < 0.5); // Should achieve at least 2:1 compression

    // Calculate bytes per value
    const bytes_per_value = @as(f64, @floatFromInt(stats.total_compressed)) /
        @as(f64, @floatFromInt(points.items.len));

    // Should achieve < 12 bytes per value with Gorilla compression
    try std.testing.expect(bytes_per_value < 12.0);

    std.debug.print("\nCompression Stats:\n", .{});
    std.debug.print("  Total chunks: {}\n", .{stats.total_chunks});
    std.debug.print("  Compression ratio: {d:.2}%\n", .{stats.ratio * 100});
    std.debug.print("  Bytes per value: {d:.2}\n", .{bytes_per_value});
    std.debug.print("  Avg chunk size: {d:.0} bytes\n", .{stats.avg_chunk_size});
}

test "e2e_timeseries: retention policy" {
    const allocator = std.testing.allocator;

    const pid = std.os.linux.getpid();
    var dir_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&dir_buf, "/tmp/test_retention_policy_{d}", .{pid}) catch unreachable;
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var storage = try chunk_storage.ChunkStorage.init(allocator, test_dir, .{
        .retention_days = 1, // 1 day retention for testing
    });
    defer storage.deinit();

    const current_time: i64 = 1700000000000; // Current timestamp in ms
    const day_ms: i64 = 24 * 60 * 60 * 1000;

    // Add data from different time periods
    const series_id: u64 = 123;

    // Old data (2 days ago) - should be pruned
    try storage.writePoints(series_id, &[_]timeseries.Point{
        .{ .ts = current_time - 2 * day_ms, .value = 100 },
        .{ .ts = current_time - 2 * day_ms + 1000, .value = 101 },
    });

    // Yesterday's data (1 day ago) - on the boundary
    try storage.writePoints(series_id, &[_]timeseries.Point{
        .{ .ts = current_time - day_ms + 1000, .value = 200 },
        .{ .ts = current_time - day_ms + 2000, .value = 201 },
    });

    // Recent data - should be kept
    try storage.writePoints(series_id, &[_]timeseries.Point{
        .{ .ts = current_time - 3600000, .value = 300 }, // 1 hour ago
        .{ .ts = current_time - 60000, .value = 301 }, // 1 minute ago
    });

    try std.testing.expect(storage.chunks.items.len == 3);

    // Run retention
    try storage.runRetention(current_time);

    // Should have pruned old data
    try std.testing.expect(storage.chunks.items.len == 2);

    // Verify remaining chunks are recent
    for (storage.chunks.items) |chunk| {
        try std.testing.expect(chunk.end_ts > current_time - day_ms);
    }
}

test "e2e_timeseries: GQL function integration" {
    const allocator = std.testing.allocator;

    var store = timeseries.Store.init(allocator);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 42, .metric = "cpu_usage" };

    // Insert CPU usage data (0-100%)
    var points: std.ArrayList(timeseries.Point) = .{};
    defer points.deinit(allocator);

    var i: i64 = 0;
    while (i < 60) : (i += 1) { // 1 minute of data at 1Hz
        const ts = 1000000000 + i * 1000;
        // Simulate varying CPU usage
        const base_usage: i64 = 30;
        const spike: i64 = if (i >= 20 and i < 30) 50 else 0;
        const noise = @mod(i * 7, 10);
        const value = base_usage + spike + noise;
        try points.append(allocator, .{ .ts = ts, .value = value });
    }

    try store.insertMany(key, points.items);

    // Test last_value function
    const last_value_call = gql_functions.TSFunctionCall{
        .function_type = .last_value,
        .series_key = key,
        .params = .{ .last_value = {} },
    };

    var last_result = try gql_functions.executeFunction(&store, last_value_call, allocator);
    defer gql_functions.deinitValue(&last_result, allocator);
    switch (last_result) {
        .object => |obj| {
            const ts = obj.get("ts").?.integer;
            const val = obj.get("value").?.integer;
            try std.testing.expect(ts == 1000059000);
            try std.testing.expect(val >= 30 and val <= 100);
        },
        else => return error.UnexpectedResult,
    }

    // Test value_at function
    const value_at_call = gql_functions.TSFunctionCall{
        .function_type = .value_at,
        .series_key = key,
        .params = .{ .value_at = .{ .timestamp = 1000025000 } }, // During spike
    };

    var at_result = try gql_functions.executeFunction(&store, value_at_call, allocator);
    defer gql_functions.deinitValue(&at_result, allocator);
    switch (at_result) {
        .object => |obj| {
            const val = obj.get("value").?.integer;
            try std.testing.expect(val >= 80); // Should be high during spike
        },
        else => return error.UnexpectedResult,
    }

    // Test interpolation
    const interpolate_call = gql_functions.TSFunctionCall{
        .function_type = .interpolate,
        .series_key = key,
        .params = .{
            .interpolate = .{
                .timestamp = 1000025500, // Between two points
                .method = .linear,
            },
        },
    };

    var interp_result = try gql_functions.executeFunction(&store, interpolate_call, allocator);
    defer gql_functions.deinitValue(&interp_result, allocator);
    try std.testing.expect(interp_result == .object);

    // Test moving average
    const moving_avg_call = gql_functions.TSFunctionCall{
        .function_type = .moving_avg,
        .series_key = key,
        .params = .{
            .moving_avg = .{
                .window_ms = 5000, // 5 second window
                .step_ms = 1000, // 1 second step
            },
        },
    };

    var avg_result = try gql_functions.executeFunction(&store, moving_avg_call, allocator);
    defer gql_functions.deinitValue(&avg_result, allocator);
    switch (avg_result) {
        .array => |arr| {
            try std.testing.expect(arr.len > 50); // Should have many averaged points

            // Check that averages during spike are higher
            var spike_found = false;
            for (arr) |item| {
                switch (item) {
                    .object => |obj| {
                        const ts = obj.get("ts").?.integer;
                        const avg = obj.get("avg").?.integer;
                        if (ts >= 1000020000 and ts <= 1000030000) {
                            if (avg > 60) spike_found = true;
                        }
                    },
                    else => {},
                }
            }
            try std.testing.expect(spike_found);
        },
        else => return error.UnexpectedResult,
    }

    // Test rate calculation
    const rate_call = gql_functions.TSFunctionCall{
        .function_type = .rate,
        .series_key = key,
        .params = .{
            .rate = .{
                .interval_ms = 1000, // Per second rate
            },
        },
    };

    var rate_result = try gql_functions.executeFunction(&store, rate_call, allocator);
    defer gql_functions.deinitValue(&rate_result, allocator);
    switch (rate_result) {
        .array => |arr| {
            try std.testing.expect(arr.len == points.items.len - 1);

            // Check for high rate during spike onset
            for (arr) |item| {
                switch (item) {
                    .object => |obj| {
                        const ts = obj.get("ts").?.integer;
                        const rate = obj.get("rate").?.float;
                        if (ts == 1000020000) { // Start of spike
                            try std.testing.expect(rate > 10.0); // High positive rate
                        }
                        if (ts == 1000030000) { // End of spike
                            try std.testing.expect(rate < -10.0); // High negative rate
                        }
                    },
                    else => {},
                }
            }
        },
        else => return error.UnexpectedResult,
    }
}

test "e2e_timeseries: performance benchmark" {
    const allocator = std.testing.allocator;

    var store = timeseries.Store.init(allocator);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 1, .metric = "benchmark" };

    // Benchmark write performance
    const num_points = 1000000; // 1M points
    var points = try allocator.alloc(timeseries.Point, num_points);
    defer allocator.free(points);

    var i: usize = 0;
    while (i < num_points) : (i += 1) {
        points[i] = .{
            .ts = @intCast(1000000000 + i),
            .value = @intCast(i % 1000),
        };
    }

    const start_time = std.time.milliTimestamp();
    try store.insertMany(key, points);
    const write_time = std.time.milliTimestamp() - start_time;

    const write_throughput = @as(f64, @floatFromInt(num_points * 1000)) / @as(f64, @floatFromInt(write_time));

    std.debug.print("\nPerformance Metrics:\n", .{});
    std.debug.print("  Write throughput: {d:.0} points/sec\n", .{write_throughput});
    std.debug.print("  Write time: {} ms for {} points\n", .{ write_time, num_points });

    // Benchmark query performance
    const query_start = std.time.milliTimestamp();

    // Run various queries
    _ = store.last(key);
    _ = store.valueBefore(key, 1000500000);
    const samples = try store.sampleBy(key, 10000, 1000000000, 1001000000, .avg, allocator);
    allocator.free(samples);

    const query_time = std.time.milliTimestamp() - query_start;

    std.debug.print("  Query time: {} ms\n", .{query_time});

    // Memory usage approximation
    const series = store.by_key.get(store.hashKey(key)).?;
    const memory_used = series.points.capacity * @sizeOf(timeseries.Point);
    const bytes_per_point = @as(f64, @floatFromInt(memory_used)) / @as(f64, @floatFromInt(num_points));

    std.debug.print("  Memory usage: {d:.2} bytes per point\n", .{bytes_per_point});

    // Performance assertions (relaxed for Debug builds)
    try std.testing.expect(write_throughput > 100000); // > 100K points/sec (Debug)
    try std.testing.expect(query_time < 5000); // < 5s for queries (Debug)
    try std.testing.expect(bytes_per_point < 32); // < 32 bytes per point in memory
}
