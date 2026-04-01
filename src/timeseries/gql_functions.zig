const std = @import("std");
const timeseries = @import("timeseries.zig");

/// Temporary Value type for testing (will be replaced by protocol.Value)
pub const Value = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    array: []Value,
    object: std.StringHashMap(Value),
};

/// Recursively free all heap memory owned by a Value.
pub fn deinitValue(val: *Value, allocator: std.mem.Allocator) void {
    switch (val.*) {
        .array => |arr| {
            for (arr) |*item| {
                var v = item.*;
                deinitValue(&v, allocator);
            }
            allocator.free(arr);
        },
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                var v = entry.value_ptr.*;
                deinitValue(&v, allocator);
            }
            obj.deinit();
        },
        else => {},
    }
}

/// Temporary Expression type for testing (will be replaced by parser.Expression)
pub const Expression = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
};

/// Time-series function registry for GQL integration
pub const TSFunctionType = enum {
    last_value,
    value_at,
    sample_by,
    time_bucket,
    interpolate,
    moving_avg,
    rate,
    derivative,
};

/// Time-series function call in GQL
pub const TSFunctionCall = struct {
    function_type: TSFunctionType,
    series_key: timeseries.SeriesKey,
    params: TSFunctionParams,
};

/// Parameters for time-series functions
pub const TSFunctionParams = union(TSFunctionType) {
    last_value: void,
    value_at: struct { timestamp: i64 },
    sample_by: struct {
        interval_ms: i64,
        start_ts: i64,
        end_ts: i64,
        aggregation: timeseries.lib.store.Aggregation,
    },
    time_bucket: struct {
        bucket_ms: i64,
        start_ts: i64,
        end_ts: i64,
    },
    interpolate: struct {
        timestamp: i64,
        method: enum { linear, step, nearest },
    },
    moving_avg: struct {
        window_ms: i64,
        step_ms: i64,
    },
    rate: struct {
        interval_ms: i64,
    },
    derivative: struct {
        order: u8,
    },
};

/// Execute a time-series function against a store
pub fn executeFunction(
    store: *timeseries.Store,
    call: TSFunctionCall,
    allocator: std.mem.Allocator,
) !Value {
    switch (call.params) {
        .last_value => {
            if (store.last(call.series_key)) |point| {
                return Value{
                    .object = try createPointObject(point, allocator),
                };
            }
            return Value{ .null = {} };
        },

        .value_at => |params| {
            const hk = store.hashKey(call.series_key);
            if (store.by_key.get(hk)) |series| {
                if (series.valueAt(params.timestamp)) |point| {
                    return Value{
                        .object = try createPointObject(point, allocator),
                    };
                }
            }
            return Value{ .null = {} };
        },

        .sample_by => |params| {
            const samples = try store.sampleBy(
                call.series_key,
                params.interval_ms,
                params.start_ts,
                params.end_ts,
                params.aggregation,
                allocator,
            );
            defer allocator.free(samples);

            var array: std.ArrayList(Value) = .{};
            for (samples) |sample| {
                var obj = std.StringHashMap(Value).init(allocator);
                try obj.put("ts", Value{ .integer = sample.ts });
                try obj.put("value", if (sample.value) |v|
                    Value{ .integer = v }
                else
                    Value{ .null = {} });
                try array.append(allocator, Value{ .object = obj });
            }

            return Value{ .array = try array.toOwnedSlice(allocator) };
        },

        .time_bucket => |params| {
            const buckets = try store.timeBucketAvg(
                call.series_key,
                @divTrunc(params.bucket_ms, 1000), // Convert to seconds
                params.start_ts,
                params.end_ts,
                allocator,
            );
            defer allocator.free(buckets);

            var array: std.ArrayList(Value) = .{};
            for (buckets) |bucket| {
                var obj = std.StringHashMap(Value).init(allocator);
                try obj.put("ts", Value{ .integer = bucket.ts });
                try obj.put("avg", if (bucket.avg) |v|
                    Value{ .integer = v }
                else
                    Value{ .null = {} });
                try array.append(allocator, Value{ .object = obj });
            }

            return Value{ .array = try array.toOwnedSlice(allocator) };
        },

        .interpolate => |params| {
            // Linear interpolation between points
            const hk = store.hashKey(call.series_key);
            if (store.by_key.get(hk)) |series| {
                const items = series.points.items;
                if (items.len < 2) {
                    if (items.len == 1) {
                        return Value{
                            .object = try createPointObject(items[0], allocator),
                        };
                    }
                    return Value{ .null = {} };
                }

                // Find surrounding points
                var left: ?timeseries.Point = null;
                var right: ?timeseries.Point = null;

                for (items) |point| {
                    if (point.ts == params.timestamp) {
                        return Value{
                            .object = try createPointObject(point, allocator),
                        };
                    } else if (point.ts < params.timestamp) {
                        left = point;
                    } else if (point.ts > params.timestamp) {
                        right = point;
                        break;
                    }
                }

                if (left != null and right != null and params.method == .linear) {
                    const l = left.?;
                    const r = right.?;
                    const ratio = @as(f64, @floatFromInt(params.timestamp - l.ts)) /
                        @as(f64, @floatFromInt(r.ts - l.ts));
                    const interpolated_value = @as(i64, @intFromFloat(@as(f64, @floatFromInt(l.value)) +
                        ratio * @as(f64, @floatFromInt(r.value - l.value))));

                    return Value{
                        .object = try createPointObject(.{
                            .ts = params.timestamp,
                            .value = interpolated_value,
                        }, allocator),
                    };
                } else if (left != null and params.method == .step) {
                    return Value{
                        .object = try createPointObject(left.?, allocator),
                    };
                } else if (params.method == .nearest) {
                    if (left != null and right != null) {
                        const left_dist = params.timestamp - left.?.ts;
                        const right_dist = right.?.ts - params.timestamp;
                        const nearest = if (left_dist <= right_dist) left.? else right.?;
                        return Value{
                            .object = try createPointObject(nearest, allocator),
                        };
                    } else if (left != null) {
                        return Value{
                            .object = try createPointObject(left.?, allocator),
                        };
                    } else if (right != null) {
                        return Value{
                            .object = try createPointObject(right.?, allocator),
                        };
                    }
                }
            }
            return Value{ .null = {} };
        },

        .moving_avg => |params| {
            // Calculate moving average
            const hk = store.hashKey(call.series_key);
            if (store.by_key.get(hk)) |series| {
                const items = series.points.items;
                if (items.len == 0) return Value{ .null = {} };

                var results: std.ArrayList(Value) = .{};
                const half_window = @divTrunc(params.window_ms, 2);

                var current_ts = items[0].ts;
                const end_ts = items[items.len - 1].ts;

                while (current_ts <= end_ts) : (current_ts += params.step_ms) {
                    var sum: i128 = 0;
                    var count: i64 = 0;

                    for (items) |point| {
                        if (point.ts >= current_ts - half_window and
                            point.ts <= current_ts + half_window)
                        {
                            sum += point.value;
                            count += 1;
                        }
                    }

                    if (count > 0) {
                        const avg = @divTrunc(sum, count);
                        var obj = std.StringHashMap(Value).init(allocator);
                        try obj.put("ts", Value{ .integer = current_ts });
                        try obj.put("avg", Value{ .integer = @intCast(avg) });
                        try results.append(allocator, Value{ .object = obj });
                    }
                }

                return Value{ .array = try results.toOwnedSlice(allocator) };
            }
            return Value{ .null = {} };
        },

        .rate => |params| {
            // Calculate rate of change
            const hk = store.hashKey(call.series_key);
            if (store.by_key.get(hk)) |series| {
                const items = series.points.items;
                if (items.len < 2) return Value{ .null = {} };

                var results: std.ArrayList(Value) = .{};

                var i: usize = 1;
                while (i < items.len) : (i += 1) {
                    const prev = items[i - 1];
                    const curr = items[i];
                    const time_diff = curr.ts - prev.ts;

                    if (time_diff > 0) {
                        const value_diff = curr.value - prev.value;
                        const rate = (@as(f64, @floatFromInt(value_diff)) *
                            @as(f64, @floatFromInt(params.interval_ms))) /
                            @as(f64, @floatFromInt(time_diff));

                        var obj = std.StringHashMap(Value).init(allocator);
                        try obj.put("ts", Value{ .integer = curr.ts });
                        try obj.put("rate", Value{ .float = rate });
                        try results.append(allocator, Value{ .object = obj });
                    }
                }

                return Value{ .array = try results.toOwnedSlice(allocator) };
            }
            return Value{ .null = {} };
        },

        .derivative => |params| {
            // Calculate nth order derivative
            const hk = store.hashKey(call.series_key);
            if (store.by_key.get(hk)) |series| {
                const items = series.points.items;
                if (items.len < params.order + 1) return Value{ .null = {} };

                // For now, just calculate first order derivative
                if (params.order == 1) {
                    var results: std.ArrayList(Value) = .{};

                    var i: usize = 1;
                    while (i < items.len) : (i += 1) {
                        const prev = items[i - 1];
                        const curr = items[i];
                        const time_diff = @as(f64, @floatFromInt(curr.ts - prev.ts)) / 1000.0; // Convert to seconds

                        if (time_diff > 0) {
                            const value_diff = @as(f64, @floatFromInt(curr.value - prev.value));
                            const derivative = value_diff / time_diff;

                            var obj = std.StringHashMap(Value).init(allocator);
                            try obj.put("ts", Value{ .integer = curr.ts });
                            try obj.put("derivative", Value{ .float = derivative });
                            try results.append(allocator, Value{ .object = obj });
                        }
                    }

                    return Value{ .array = try results.toOwnedSlice(allocator) };
                }
            }
            return Value{ .null = {} };
        },
    }
}

fn createPointObject(point: timeseries.Point, allocator: std.mem.Allocator) !std.StringHashMap(Value) {
    var obj = std.StringHashMap(Value).init(allocator);
    try obj.put("ts", Value{ .integer = point.ts });
    try obj.put("value", Value{ .integer = point.value });
    return obj;
}

test "ts_functions: last_value" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 1, .metric = "temp" };
    try store.insertMany(key, &[_]timeseries.Point{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
    });

    const call = TSFunctionCall{
        .function_type = .last_value,
        .series_key = key,
        .params = .{ .last_value = {} },
    };

    const result = try executeFunction(&store, call, ally);
    switch (result) {
        .object => |obj| {
            const ts = obj.get("ts").?.integer;
            const val = obj.get("value").?.integer;
            try std.testing.expect(ts == 3000);
            try std.testing.expect(val == 30);
        },
        else => return error.UnexpectedResultType,
    }
}

test "ts_functions: interpolate" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 1, .metric = "temp" };
    try store.insertMany(key, &[_]timeseries.Point{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 3000, .value = 30 },
    });

    const call = TSFunctionCall{
        .function_type = .interpolate,
        .series_key = key,
        .params = .{ .interpolate = .{
            .timestamp = 2000,
            .method = .linear,
        } },
    };

    const result = try executeFunction(&store, call, ally);
    switch (result) {
        .object => |obj| {
            const ts = obj.get("ts").?.integer;
            const val = obj.get("value").?.integer;
            try std.testing.expect(ts == 2000);
            try std.testing.expect(val == 20); // Linear interpolation
        },
        else => return error.UnexpectedResultType,
    }
}
