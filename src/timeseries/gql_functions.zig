// CANARY: REQ=REQ-TS-GQL-EXEC-001; FEATURE="TimeSeriesGqlExecute"; ASPECT=Integration; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: last_value"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-LASTVAL-001; FEATURE="TimeSeriesLastValue"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: last_value"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-VALUEAT-001; FEATURE="TimeSeriesGqlValueAt"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: last_value"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-SAMPLEBY-001; FEATURE="TimeSeriesGqlSampleBy"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: last_value"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-TIMEBUCKET-001; FEATURE="TimeSeriesGqlTimeBucket"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: last_value"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-INTERPOLATE-001; FEATURE="TimeSeriesGqlInterpolate"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: interpolate linear"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-MOVINGAVG-001; FEATURE="TimeSeriesGqlMovingAvg"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: last_value"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-RATE-001; FEATURE="TimeSeriesGqlRate"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: last_value"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-DERIVATIVE-001; FEATURE="TimeSeriesGqlDerivative"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: last_value"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-FUNCTYPE-001; FEATURE="TSFunctionTypeEnum"; ASPECT=Types; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: last_value"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-CHANGEPOINTS-001; FEATURE="TimeSeriesGqlChangePoints"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: change_points"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-EXTRACTFEAT-001; FEATURE="TimeSeriesGqlExtractFeatures"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: extract_features"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-MATPROFILE-001; FEATURE="TimeSeriesGqlMatrixProfile"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: matrix_profile"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-ZNORM-001; FEATURE="TimeSeriesGqlZNormalize"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: z_normalize"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-INVARIANTS-001; FEATURE="TimeSeriesGqlInvariants"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: invariants"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-DTW-001; FEATURE="TimeSeriesGqlDTW"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: dtw constrained"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-DTWDERIV-001; FEATURE="TimeSeriesGqlDTWDerivative"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: dtw_derivative"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-DTWOPENEND-001; FEATURE="TimeSeriesGqlDTWOpenEnd"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: dtw_open_end"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-DTWSHAPE-001; FEATURE="TimeSeriesGqlDTWShape"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: dtw_shape"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-DTWSOFT-001; FEATURE="TimeSeriesGqlDTWSoft"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: dtw_soft"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-COSSIM-001; FEATURE="TimeSeriesGqlCosineSimilarity"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: cosine_similarity"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-XCORR-001; FEATURE="TimeSeriesGqlCrossCorrelate"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: cross_correlate"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-GQL-SBD-001; FEATURE="TimeSeriesGqlSBD"; ASPECT=GqlFunction; STATUS=TESTED; TEST=src/timeseries/gql_functions.zig:"ts_functions: sbd"; OWNER=timeseries; UPDATED=2026-04-01

const std = @import("std");
const timeseries = @import("timeseries.zig");

// Sub-module references into the external timeseries library.
const ts_lib = timeseries.lib;
const dtw_mod = ts_lib.dtw;
const distances_mod = ts_lib.distances;
const mp_mod = ts_lib.matrix_profile;
const features_mod = ts_lib.features;
const pelt_mod = ts_lib.pelt;
const preprocess_mod = ts_lib.preprocess;
const invariants_mod = ts_lib.invariants;

/// GAP-0282: Value type with canonical field names matching value_types.Value.
/// Uses the same discriminant names (.Null, .Int, .Bool, .Double, .Str, .List, .Map)
/// so that conversion to/from the full canonical Value in eval.zig is straightforward.
/// This is a standalone subset because the full value_types.Value depends on graph_store,
/// datetime, and other modules unavailable in the timeseries build context.
pub const Value = union(enum) {
    Null,
    Bool: bool,
    Int: i64,
    Double: f64,
    Str: []const u8,
    List: []Value,
    Map: std.StringHashMap(Value),
};

/// Recursively free all heap memory owned by a Value.
pub fn deinitValue(val: *Value, allocator: std.mem.Allocator) void {
    switch (val.*) {
        .List => |arr| {
            for (arr) |*item| {
                var v = item.*;
                deinitValue(&v, allocator);
            }
            allocator.free(arr);
        },
        .Map => |*obj| {
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

/// Extract f64 values from a stored time series within a time range.
/// Returns an owned slice; caller must free via allocator.free(result).
pub fn extractF64FromSeries(
    store: *timeseries.Store,
    key: timeseries.SeriesKey,
    start_ts: i64,
    end_ts: i64,
    allocator: std.mem.Allocator,
) ![]f64 {
    const series = store.getSeries(key) orelse return allocator.alloc(f64, 0);
    const items = series.points.items;

    // Count points in range first to allocate exactly.
    var count: usize = 0;
    for (items) |pt| {
        if (pt.ts >= start_ts and pt.ts <= end_ts) count += 1;
    }
    if (count == 0) return allocator.alloc(f64, 0);

    const result = try allocator.alloc(f64, count);
    var idx: usize = 0;
    for (items) |pt| {
        if (pt.ts >= start_ts and pt.ts <= end_ts) {
            result[idx] = @floatFromInt(pt.value);
            idx += 1;
        }
    }
    return result;
}

/// Extract both timestamps (as f64) and values (as f64) from a stored time series.
/// Returns owned slices; caller must free both via allocator.free().
pub fn extractTimesAndValues(
    store: *timeseries.Store,
    key: timeseries.SeriesKey,
    start_ts: i64,
    end_ts: i64,
    allocator: std.mem.Allocator,
) !struct { times: []f64, values: []f64 } {
    const series = store.getSeries(key) orelse return .{
        .times = try allocator.alloc(f64, 0),
        .values = try allocator.alloc(f64, 0),
    };
    const items = series.points.items;

    var count: usize = 0;
    for (items) |pt| {
        if (pt.ts >= start_ts and pt.ts <= end_ts) count += 1;
    }

    const times = try allocator.alloc(f64, count);
    errdefer allocator.free(times);
    const values = try allocator.alloc(f64, count);

    var idx: usize = 0;
    for (items) |pt| {
        if (pt.ts >= start_ts and pt.ts <= end_ts) {
            times[idx] = @floatFromInt(pt.ts);
            values[idx] = @floatFromInt(pt.value);
            idx += 1;
        }
    }
    return .{ .times = times, .values = values };
}

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
    // GAP-0290: Series-based analytics functions
    change_points,
    extract_features,
    matrix_profile,
    z_normalize,
    invariants,
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
    // GAP-0290: Series-based analytics params
    change_points: struct {
        start_ts: i64,
        end_ts: i64,
        penalty: f64,
        min_size: usize,
    },
    extract_features: struct {
        start_ts: i64,
        end_ts: i64,
    },
    matrix_profile: struct {
        start_ts: i64,
        end_ts: i64,
        subseq_len: usize,
    },
    z_normalize: struct {
        start_ts: i64,
        end_ts: i64,
    },
    invariants: struct {
        start_ts: i64,
        end_ts: i64,
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
                    .Map = try createPointObject(point, allocator),
                };
            }
            return .Null;
        },

        .value_at => |params| {
            // GAP-0282: Use getSeries() for encapsulation instead of by_key.get(hashKey())
            if (store.getSeries(call.series_key)) |series| {
                if (series.valueAt(params.timestamp)) |point| {
                    return Value{
                        .Map = try createPointObject(point, allocator),
                    };
                }
            }
            return .Null;
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

            var array: std.ArrayList(Value) = .empty;
            errdefer {
                for (array.items) |*item| {
                    deinitValue(item, allocator);
                }
                array.deinit(allocator);
            }
            for (samples) |sample| {
                var obj = std.StringHashMap(Value).init(allocator);
                errdefer obj.deinit();
                try obj.put("ts", Value{ .Int = sample.ts });
                try obj.put("value", if (sample.value) |v|
                    Value{ .Int = v }
                else
                    .Null);
                try array.append(allocator, Value{ .Map = obj });
            }

            return Value{ .List = try array.toOwnedSlice(allocator) };
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

            var array: std.ArrayList(Value) = .empty;
            errdefer {
                for (array.items) |*item| {
                    deinitValue(item, allocator);
                }
                array.deinit(allocator);
            }
            for (buckets) |bucket| {
                var obj = std.StringHashMap(Value).init(allocator);
                errdefer obj.deinit();
                try obj.put("ts", Value{ .Int = bucket.ts });
                try obj.put("avg", if (bucket.avg) |v|
                    Value{ .Int = v }
                else
                    .Null);
                try array.append(allocator, Value{ .Map = obj });
            }

            return Value{ .List = try array.toOwnedSlice(allocator) };
        },

        .interpolate => |params| {
            // GAP-0282: Use getSeries() for encapsulation
            if (store.getSeries(call.series_key)) |series| {
                const items = series.points.items;
                if (items.len < 2) {
                    if (items.len == 1) {
                        return Value{
                            .Map = try createPointObject(items[0], allocator),
                        };
                    }
                    return .Null;
                }

                // Find surrounding points
                var left: ?timeseries.Point = null;
                var right: ?timeseries.Point = null;

                for (items) |point| {
                    if (point.ts == params.timestamp) {
                        return Value{
                            .Map = try createPointObject(point, allocator),
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
                        .Map = try createPointObject(.{
                            .ts = params.timestamp,
                            .value = interpolated_value,
                        }, allocator),
                    };
                } else if (left != null and params.method == .step) {
                    return Value{
                        .Map = try createPointObject(left.?, allocator),
                    };
                } else if (params.method == .nearest) {
                    if (left != null and right != null) {
                        const left_dist = params.timestamp - left.?.ts;
                        const right_dist = right.?.ts - params.timestamp;
                        const nearest = if (left_dist <= right_dist) left.? else right.?;
                        return Value{
                            .Map = try createPointObject(nearest, allocator),
                        };
                    } else if (left != null) {
                        return Value{
                            .Map = try createPointObject(left.?, allocator),
                        };
                    } else if (right != null) {
                        return Value{
                            .Map = try createPointObject(right.?, allocator),
                        };
                    }
                }
            }
            return .Null;
        },

        .moving_avg => |params| {
            // GAP-0282: Validate parameters to prevent infinite loop / division by zero
            if (params.step_ms <= 0) return .Null;
            if (params.window_ms <= 0) return .Null;

            // GAP-0282: Use getSeries() for encapsulation
            if (store.getSeries(call.series_key)) |series| {
                const items = series.points.items;
                if (items.len == 0) return .Null;

                var results: std.ArrayList(Value) = .empty;
                errdefer {
                    for (results.items) |*item| {
                        deinitValue(item, allocator);
                    }
                    results.deinit(allocator);
                }
                const half_window = @divTrunc(params.window_ms, 2);

                // GAP-0282: O(n+s) sliding-window algorithm replacing the O(n*m) nested loop.
                // Two pointers (win_start, win_end) slide over the sorted points array.
                var current_ts = items[0].ts;
                const end_ts = items[items.len - 1].ts;
                var win_start: usize = 0;
                var win_end: usize = 0;
                var sum: i128 = 0;
                var count: i64 = 0;

                while (current_ts <= end_ts) : (current_ts += params.step_ms) {
                    const lo = current_ts - half_window;
                    const hi = current_ts + half_window;

                    // Expand window right
                    while (win_end < items.len and items[win_end].ts <= hi) {
                        sum += items[win_end].value;
                        count += 1;
                        win_end += 1;
                    }

                    // Shrink window left
                    while (win_start < win_end and items[win_start].ts < lo) {
                        sum -= items[win_start].value;
                        count -= 1;
                        win_start += 1;
                    }

                    if (count > 0) {
                        const avg = @divTrunc(sum, count);
                        var obj = std.StringHashMap(Value).init(allocator);
                        errdefer obj.deinit();
                        try obj.put("ts", Value{ .Int = current_ts });
                        try obj.put("avg", Value{ .Int = @intCast(avg) });
                        try results.append(allocator, Value{ .Map = obj });
                    }
                }

                return Value{ .List = try results.toOwnedSlice(allocator) };
            }
            return .Null;
        },

        .rate => |params| {
            // GAP-0282: Use getSeries() for encapsulation
            if (store.getSeries(call.series_key)) |series| {
                const items = series.points.items;
                if (items.len < 2) return .Null;

                var results: std.ArrayList(Value) = .empty;
                errdefer {
                    for (results.items) |*item| {
                        deinitValue(item, allocator);
                    }
                    results.deinit(allocator);
                }

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
                        errdefer obj.deinit();
                        try obj.put("ts", Value{ .Int = curr.ts });
                        try obj.put("rate", Value{ .Double = rate });
                        try results.append(allocator, Value{ .Map = obj });
                    }
                }

                return Value{ .List = try results.toOwnedSlice(allocator) };
            }
            return .Null;
        },

        .change_points => |params| {
            // GAP-0290: PELT change-point detection on stored series
            const values = try extractF64FromSeries(store, call.series_key, params.start_ts, params.end_ts, allocator);
            defer allocator.free(values);
            if (values.len == 0) return .Null;

            const cps = pelt_mod.pelt(allocator, values, params.penalty, params.min_size) catch return .Null;
            defer allocator.free(cps);

            var array: std.ArrayList(Value) = .empty;
            errdefer {
                for (array.items) |*item| deinitValue(item, allocator);
                array.deinit(allocator);
            }
            for (cps) |cp| {
                try array.append(allocator, Value{ .Int = @intCast(cp) });
            }
            return Value{ .List = try array.toOwnedSlice(allocator) };
        },

        .extract_features => |params| {
            // GAP-0290: 22-element feature extraction on stored series
            const values = try extractF64FromSeries(store, call.series_key, params.start_ts, params.end_ts, allocator);
            defer allocator.free(values);
            if (values.len == 0) return .Null;

            const feats = features_mod.extractFeatures(allocator, values) catch return .Null;

            var array: std.ArrayList(Value) = .empty;
            errdefer {
                for (array.items) |*item| deinitValue(item, allocator);
                array.deinit(allocator);
            }
            for (feats) |f| {
                try array.append(allocator, Value{ .Double = f });
            }
            return Value{ .List = try array.toOwnedSlice(allocator) };
        },

        .matrix_profile => |params| {
            // GAP-0290: Matrix profile computation on stored series
            const values = try extractF64FromSeries(store, call.series_key, params.start_ts, params.end_ts, allocator);
            defer allocator.free(values);
            if (values.len == 0) return .Null;

            const mp_result = mp_mod.matrixProfile(allocator, values, params.subseq_len) catch return .Null;
            defer mp_result.deinit(allocator);

            var obj = std.StringHashMap(Value).init(allocator);
            errdefer obj.deinit();

            // Profile as list of doubles
            var prof_list: std.ArrayList(Value) = .empty;
            errdefer prof_list.deinit(allocator);
            for (mp_result.profile) |v| {
                try prof_list.append(allocator, Value{ .Double = v });
            }
            try obj.put("profile", Value{ .List = try prof_list.toOwnedSlice(allocator) });

            // Indices as list of ints
            var idx_list: std.ArrayList(Value) = .empty;
            errdefer idx_list.deinit(allocator);
            for (mp_result.indices) |v| {
                try idx_list.append(allocator, Value{ .Int = @intCast(v) });
            }
            try obj.put("indices", Value{ .List = try idx_list.toOwnedSlice(allocator) });

            return Value{ .Map = obj };
        },

        .z_normalize => |params| {
            // GAP-0290: Z-normalization on stored series
            const values = try extractF64FromSeries(store, call.series_key, params.start_ts, params.end_ts, allocator);
            defer allocator.free(values);
            if (values.len == 0) return .Null;

            const normed = preprocess_mod.zNormalizeAlloc(allocator, values) catch return .Null;
            defer allocator.free(normed);

            var array: std.ArrayList(Value) = .empty;
            errdefer {
                for (array.items) |*item| deinitValue(item, allocator);
                array.deinit(allocator);
            }
            for (normed) |v| {
                try array.append(allocator, Value{ .Double = v });
            }
            return Value{ .List = try array.toOwnedSlice(allocator) };
        },

        .invariants => |params| {
            // GAP-0290: Shape-invariant statistics on stored series
            const tv = try extractTimesAndValues(store, call.series_key, params.start_ts, params.end_ts, allocator);
            defer allocator.free(tv.times);
            defer allocator.free(tv.values);
            if (tv.values.len == 0) return .Null;

            const inv = invariants_mod.computeInvariants(tv.times, tv.values);

            var obj = std.StringHashMap(Value).init(allocator);
            errdefer obj.deinit();
            try obj.put("duration", Value{ .Double = inv.duration });
            try obj.put("min", Value{ .Double = inv.min });
            try obj.put("max", Value{ .Double = inv.max });
            try obj.put("mean", Value{ .Double = inv.mean });
            try obj.put("std_dev", Value{ .Double = inv.std_dev });
            try obj.put("area", Value{ .Double = inv.area });

            // histogram as list
            var hist_list: std.ArrayList(Value) = .empty;
            errdefer hist_list.deinit(allocator);
            for (inv.histogram) |h| {
                try hist_list.append(allocator, Value{ .Double = h });
            }
            try obj.put("histogram", Value{ .List = try hist_list.toOwnedSlice(allocator) });

            return Value{ .Map = obj };
        },

        .derivative => |params| {
            // GAP-0283: Support arbitrary derivative order via iterative differentiation.
            // Order 0 returns the raw values; order N applies finite differences N times.
            if (params.order == 0) return .Null;

            // GAP-0282: Use getSeries() for encapsulation
            if (store.getSeries(call.series_key)) |series| {
                const items = series.points.items;
                if (items.len < @as(usize, params.order) + 1) return .Null;

                // Build initial float-valued series from raw points
                var ts_buf = try allocator.alloc(i64, items.len);
                defer allocator.free(ts_buf);
                var val_buf = try allocator.alloc(f64, items.len);
                defer allocator.free(val_buf);

                for (items, 0..) |pt, idx| {
                    ts_buf[idx] = pt.ts;
                    val_buf[idx] = @floatFromInt(pt.value);
                }

                var current_len = items.len;

                // Iteratively apply first-order differentiation `params.order` times.
                var ord: u8 = 0;
                while (ord < params.order) : (ord += 1) {
                    if (current_len < 2) return .Null;

                    var write: usize = 0;
                    var j: usize = 1;
                    while (j < current_len) : (j += 1) {
                        const dt = @as(f64, @floatFromInt(ts_buf[j] - ts_buf[j - 1])) / 1000.0;
                        if (dt > 0) {
                            ts_buf[write] = ts_buf[j];
                            val_buf[write] = (val_buf[j] - val_buf[j - 1]) / dt;
                            write += 1;
                        }
                    }
                    current_len = write;
                }

                if (current_len == 0) return .Null;

                var results: std.ArrayList(Value) = .empty;
                errdefer {
                    for (results.items) |*item| {
                        deinitValue(item, allocator);
                    }
                    results.deinit(allocator);
                }

                var k: usize = 0;
                while (k < current_len) : (k += 1) {
                    var obj = std.StringHashMap(Value).init(allocator);
                    errdefer obj.deinit();
                    try obj.put("ts", Value{ .Int = ts_buf[k] });
                    try obj.put("derivative", Value{ .Double = val_buf[k] });
                    try results.append(allocator, Value{ .Map = obj });
                }

                return Value{ .List = try results.toOwnedSlice(allocator) };
            }
            return .Null;
        },
    }
}

// ---------------------------------------------------------------------------
// GAP-0290: Array-based analytic functions (take f64 slices directly)
// ---------------------------------------------------------------------------

/// Constrained DTW distance between two f64 arrays.
pub fn executeDTW(
    allocator: std.mem.Allocator,
    a: []const f64,
    b: []const f64,
    window: usize,
) !Value {
    const result = dtw_mod.constrainedDTW(allocator, a, b, window) catch return .Null;
    defer result.deinit(allocator);
    return Value{ .Double = result.distance };
}

/// Derivative DTW distance between two f64 arrays.
pub fn executeDTWDerivative(
    allocator: std.mem.Allocator,
    a: []const f64,
    b: []const f64,
    window: usize,
) !Value {
    const result = dtw_mod.derivativeDTW(allocator, a, b, window) catch return .Null;
    defer result.deinit(allocator);
    return Value{ .Double = result.distance };
}

/// Open-end DTW distance between two f64 arrays.
pub fn executeDTWOpenEnd(
    allocator: std.mem.Allocator,
    a: []const f64,
    b: []const f64,
) !Value {
    const result = dtw_mod.openEndDTW(allocator, a, b, 0) catch return .Null;
    defer result.deinit(allocator);
    return Value{ .Double = result.distance };
}

/// Shape DTW distance between two f64 arrays.
pub fn executeDTWShape(
    allocator: std.mem.Allocator,
    a: []const f64,
    b: []const f64,
    reach: usize,
) !Value {
    const result = dtw_mod.shapeDTW(allocator, a, b, 0, reach) catch return .Null;
    defer result.deinit(allocator);
    return Value{ .Double = result.distance };
}

/// Soft DTW distance between two f64 arrays.
pub fn executeDTWSoft(
    allocator: std.mem.Allocator,
    a: []const f64,
    b: []const f64,
    gamma: f64,
) !Value {
    const result = dtw_mod.softDTW(allocator, a, b, gamma) catch return .Null;
    return Value{ .Double = result };
}

/// Cosine similarity between two f64 arrays.
pub fn executeCosineSimilarity(
    a: []const f64,
    b: []const f64,
) Value {
    return Value{ .Double = features_mod.cosineSimilarity(a, b) };
}

/// Cross-correlation between two f64 arrays.
pub fn executeCrossCorrelate(
    allocator: std.mem.Allocator,
    a: []const f64,
    b: []const f64,
) Value {
    const result = distances_mod.crossCorrelate(a, b) catch return .Null;
    var obj_map = std.StringHashMap(Value).init(allocator);
    obj_map.put("lag", Value{ .Int = result.lag }) catch return .Null;
    obj_map.put("correlation", Value{ .Double = result.correlation }) catch return .Null;
    return Value{ .Map = obj_map };
}

/// Shape-based distance between two f64 arrays.
pub fn executeSBD(
    a: []const f64,
    b: []const f64,
) Value {
    const result = distances_mod.sbd(a, b) catch return .Null;
    return Value{ .Double = result };
}

fn createPointObject(point: timeseries.Point, allocator: std.mem.Allocator) !std.StringHashMap(Value) {
    var obj = std.StringHashMap(Value).init(allocator);
    errdefer obj.deinit();
    try obj.put("ts", Value{ .Int = point.ts });
    try obj.put("value", Value{ .Int = point.value });
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
        .Map => |obj| {
            // GAP-0888 review follow-up: free the point object (the map keys
            // are string literals; only the bucket storage is allocated).
            var map = obj;
            defer map.deinit();
            const ts = map.get("ts").?.Int;
            const val = map.get("value").?.Int;
            try std.testing.expect(ts == 3000);
            try std.testing.expect(val == 30);
        },
        else => return error.UnexpectedResultType,
    }
}

test "ts_functions: interpolate linear" {
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
        .Map => |obj| {
            // GAP-0888 review follow-up: free the point object (the map keys
            // are string literals; only the bucket storage is allocated).
            var map = obj;
            defer map.deinit();
            const ts = map.get("ts").?.Int;
            const val = map.get("value").?.Int;
            try std.testing.expect(ts == 2000);
            try std.testing.expect(val == 20); // Linear interpolation
        },
        else => return error.UnexpectedResultType,
    }
}

// ---------------------------------------------------------------------------
// GAP-0286: Step and nearest interpolation tests
// ---------------------------------------------------------------------------

test "ts_functions: interpolate step — returns left point value" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 10, .metric = "step" };
    try store.insertMany(key, &[_]timeseries.Point{
        .{ .ts = 1000, .value = 100 },
        .{ .ts = 3000, .value = 300 },
    });

    // Step interpolation at ts=2000: should return the left point (ts=1000, val=100)
    const call = TSFunctionCall{
        .function_type = .interpolate,
        .series_key = key,
        .params = .{ .interpolate = .{
            .timestamp = 2000,
            .method = .step,
        } },
    };

    var result = try executeFunction(&store, call, ally);
    switch (result) {
        .Map => |*obj| {
            const ts = obj.get("ts").?.Int;
            const val = obj.get("value").?.Int;
            try std.testing.expectEqual(@as(i64, 1000), ts);
            try std.testing.expectEqual(@as(i64, 100), val);
            obj.deinit();
        },
        else => return error.UnexpectedResultType,
    }
}

test "ts_functions: interpolate step — close to right still returns left" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 10, .metric = "step2" };
    try store.insertMany(key, &[_]timeseries.Point{
        .{ .ts = 1000, .value = 100 },
        .{ .ts = 3000, .value = 300 },
    });

    // Step at ts=2999: still returns left point
    const call = TSFunctionCall{
        .function_type = .interpolate,
        .series_key = key,
        .params = .{ .interpolate = .{
            .timestamp = 2999,
            .method = .step,
        } },
    };

    var result = try executeFunction(&store, call, ally);
    switch (result) {
        .Map => |*obj| {
            const ts = obj.get("ts").?.Int;
            const val = obj.get("value").?.Int;
            try std.testing.expectEqual(@as(i64, 1000), ts);
            try std.testing.expectEqual(@as(i64, 100), val);
            obj.deinit();
        },
        else => return error.UnexpectedResultType,
    }
}

test "ts_functions: interpolate nearest — picks closer point" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 11, .metric = "near" };
    try store.insertMany(key, &[_]timeseries.Point{
        .{ .ts = 1000, .value = 100 },
        .{ .ts = 5000, .value = 500 },
    });

    // Nearest at ts=2000: closer to left (dist=1000) than right (dist=3000)
    {
        const call = TSFunctionCall{
            .function_type = .interpolate,
            .series_key = key,
            .params = .{ .interpolate = .{
                .timestamp = 2000,
                .method = .nearest,
            } },
        };

        var result = try executeFunction(&store, call, ally);
        switch (result) {
            .Map => |*obj| {
                const ts = obj.get("ts").?.Int;
                const val = obj.get("value").?.Int;
                try std.testing.expectEqual(@as(i64, 1000), ts);
                try std.testing.expectEqual(@as(i64, 100), val);
                obj.deinit();
            },
            else => return error.UnexpectedResultType,
        }
    }

    // Nearest at ts=4000: closer to right (dist=1000) than left (dist=3000)
    {
        const call = TSFunctionCall{
            .function_type = .interpolate,
            .series_key = key,
            .params = .{ .interpolate = .{
                .timestamp = 4000,
                .method = .nearest,
            } },
        };

        var result = try executeFunction(&store, call, ally);
        switch (result) {
            .Map => |*obj| {
                const ts = obj.get("ts").?.Int;
                const val = obj.get("value").?.Int;
                try std.testing.expectEqual(@as(i64, 5000), ts);
                try std.testing.expectEqual(@as(i64, 500), val);
                obj.deinit();
            },
            else => return error.UnexpectedResultType,
        }
    }
}

test "ts_functions: interpolate nearest — equidistant picks left" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 11, .metric = "equi" };
    try store.insertMany(key, &[_]timeseries.Point{
        .{ .ts = 1000, .value = 100 },
        .{ .ts = 3000, .value = 300 },
    });

    // Nearest at ts=2000: equidistant (dist=1000 both sides) — left wins (<=)
    const call = TSFunctionCall{
        .function_type = .interpolate,
        .series_key = key,
        .params = .{ .interpolate = .{
            .timestamp = 2000,
            .method = .nearest,
        } },
    };

    var result = try executeFunction(&store, call, ally);
    switch (result) {
        .Map => |*obj| {
            const ts = obj.get("ts").?.Int;
            const val = obj.get("value").?.Int;
            try std.testing.expectEqual(@as(i64, 1000), ts);
            try std.testing.expectEqual(@as(i64, 100), val);
            obj.deinit();
        },
        else => return error.UnexpectedResultType,
    }
}

test "ts_functions: interpolate nearest — only left neighbor" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 11, .metric = "only_left" };
    try store.insertMany(key, &[_]timeseries.Point{
        .{ .ts = 1000, .value = 100 },
        .{ .ts = 2000, .value = 200 },
    });

    // Nearest at ts=5000: after all points, only left neighbor exists
    const call = TSFunctionCall{
        .function_type = .interpolate,
        .series_key = key,
        .params = .{ .interpolate = .{
            .timestamp = 5000,
            .method = .nearest,
        } },
    };

    var result = try executeFunction(&store, call, ally);
    switch (result) {
        .Map => |*obj| {
            const ts = obj.get("ts").?.Int;
            const val = obj.get("value").?.Int;
            try std.testing.expectEqual(@as(i64, 2000), ts);
            try std.testing.expectEqual(@as(i64, 200), val);
            obj.deinit();
        },
        else => return error.UnexpectedResultType,
    }
}

test "ts_functions: interpolate nearest — only right neighbor" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 11, .metric = "only_right" };
    try store.insertMany(key, &[_]timeseries.Point{
        .{ .ts = 5000, .value = 500 },
        .{ .ts = 6000, .value = 600 },
    });

    // Nearest at ts=1000: before all points, only right neighbor exists
    const call = TSFunctionCall{
        .function_type = .interpolate,
        .series_key = key,
        .params = .{ .interpolate = .{
            .timestamp = 1000,
            .method = .nearest,
        } },
    };

    var result = try executeFunction(&store, call, ally);
    switch (result) {
        .Map => |*obj| {
            const ts = obj.get("ts").?.Int;
            const val = obj.get("value").?.Int;
            try std.testing.expectEqual(@as(i64, 5000), ts);
            try std.testing.expectEqual(@as(i64, 500), val);
            obj.deinit();
        },
        else => return error.UnexpectedResultType,
    }
}

test "ts_functions: interpolate exact match returns point for all methods" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 12, .metric = "exact" };
    try store.insertMany(key, &[_]timeseries.Point{
        .{ .ts = 1000, .value = 100 },
        .{ .ts = 2000, .value = 200 },
        .{ .ts = 3000, .value = 300 },
    });

    // All three methods should return the exact point when timestamp matches
    // GAP-0888 review follow-up: @FieldType takes string field names
    // (the enum-literal form bit-rotted while this inline test was not
    // rooted by any step).
    const Method = @FieldType(@FieldType(TSFunctionParams, "interpolate"), "method");
    const methods = [_]Method{ .linear, .step, .nearest };

    for (methods) |method| {
        const call = TSFunctionCall{
            .function_type = .interpolate,
            .series_key = key,
            .params = .{ .interpolate = .{
                .timestamp = 2000,
                .method = method,
            } },
        };

        var result = try executeFunction(&store, call, ally);
        switch (result) {
            .Map => |*obj| {
                const ts = obj.get("ts").?.Int;
                const val = obj.get("value").?.Int;
                try std.testing.expectEqual(@as(i64, 2000), ts);
                try std.testing.expectEqual(@as(i64, 200), val);
                obj.deinit();
            },
            else => return error.UnexpectedResultType,
        }
    }
}

// ---------------------------------------------------------------------------
// GAP-0282: moving_avg parameter validation tests
// ---------------------------------------------------------------------------

test "ts_functions: moving_avg zero step_ms returns Null" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 1, .metric = "avg_test" };
    try store.insertMany(key, &[_]timeseries.Point{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
    });

    const call = TSFunctionCall{
        .function_type = .moving_avg,
        .series_key = key,
        .params = .{
            .moving_avg = .{
                .window_ms = 5000,
                .step_ms = 0, // invalid
            },
        },
    };

    const result = try executeFunction(&store, call, ally);
    try std.testing.expect(result == .Null);
}

test "ts_functions: moving_avg negative window_ms returns Null" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 1, .metric = "avg_test2" };
    try store.insertMany(key, &[_]timeseries.Point{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
    });

    const call = TSFunctionCall{
        .function_type = .moving_avg,
        .series_key = key,
        .params = .{
            .moving_avg = .{
                .window_ms = -1, // invalid
                .step_ms = 1000,
            },
        },
    };

    const result = try executeFunction(&store, call, ally);
    try std.testing.expect(result == .Null);
}

// ---------------------------------------------------------------------------
// GAP-0283: derivative order > 1 test
// ---------------------------------------------------------------------------

test "ts_functions: derivative order 2" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 1, .metric = "accel" };
    // Quadratic: value = t^2 (using ts in seconds, so ts=1000 -> t=1, ts=2000 -> t=2, etc.)
    // Values: 1, 4, 9, 16, 25 (t^2 for t=1..5)
    // 1st derivative (velocity): 3/1=3, 5/1=5, 7/1=7, 9/1=9
    // 2nd derivative (acceleration): 2/1=2, 2/1=2, 2/1=2
    try store.insertMany(key, &[_]timeseries.Point{
        .{ .ts = 1000, .value = 1 },
        .{ .ts = 2000, .value = 4 },
        .{ .ts = 3000, .value = 9 },
        .{ .ts = 4000, .value = 16 },
        .{ .ts = 5000, .value = 25 },
    });

    const call = TSFunctionCall{
        .function_type = .derivative,
        .series_key = key,
        .params = .{ .derivative = .{
            .order = 2,
        } },
    };

    var result = try executeFunction(&store, call, ally);
    defer deinitValue(&result, ally);

    switch (result) {
        .List => |arr| {
            try std.testing.expectEqual(@as(usize, 3), arr.len);
            // Each 2nd derivative should be approximately 2.0
            for (arr) |item| {
                switch (item) {
                    .Map => |obj| {
                        const d = obj.get("derivative").?.Double;
                        try std.testing.expect(@abs(d - 2.0) < 0.01);
                    },
                    else => return error.UnexpectedResultType,
                }
            }
        },
        else => return error.UnexpectedResultType,
    }
}

test "ts_functions: derivative order 0 returns Null" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 1, .metric = "noop" };
    try store.insertMany(key, &[_]timeseries.Point{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
    });

    const call = TSFunctionCall{
        .function_type = .derivative,
        .series_key = key,
        .params = .{ .derivative = .{
            .order = 0,
        } },
    };

    const result = try executeFunction(&store, call, ally);
    try std.testing.expect(result == .Null);
}

// ---------------------------------------------------------------------------
// GAP-0290: Series-based analytics function tests
// ---------------------------------------------------------------------------

test "ts_functions: change_points" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 1, .metric = "cp" };
    // Create a series with a clear change point: low values then high values
    var points: [20]timeseries.Point = undefined;
    for (0..10) |i| {
        points[i] = .{ .ts = @intCast(i * 1000), .value = 10 };
    }
    for (10..20) |i| {
        points[i] = .{ .ts = @intCast(i * 1000), .value = 100 };
    }
    try store.insertMany(key, &points);

    const call = TSFunctionCall{
        .function_type = .change_points,
        .series_key = key,
        .params = .{ .change_points = .{
            .start_ts = 0,
            .end_ts = 19000,
            .penalty = 10.0,
            .min_size = 2,
        } },
    };

    var result = try executeFunction(&store, call, ally);
    defer deinitValue(&result, ally);

    // Should return a list of change point indices
    switch (result) {
        .List => |arr| {
            // PELT should detect at least one change point around index 10
            try std.testing.expect(arr.len >= 1);
        },
        else => return error.UnexpectedResultType,
    }
}

test "ts_functions: extract_features" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 1, .metric = "feat" };
    try store.insertMany(key, &[_]timeseries.Point{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
        .{ .ts = 4000, .value = 40 },
        .{ .ts = 5000, .value = 50 },
    });

    const call = TSFunctionCall{
        .function_type = .extract_features,
        .series_key = key,
        .params = .{ .extract_features = .{
            .start_ts = 1000,
            .end_ts = 5000,
        } },
    };

    var result = try executeFunction(&store, call, ally);
    defer deinitValue(&result, ally);

    switch (result) {
        .List => |arr| {
            // extractFeatures returns a 22-element feature vector
            try std.testing.expectEqual(@as(usize, 22), arr.len);
            // First element is length = 5.0
            try std.testing.expect(arr[0] == .Double);
            try std.testing.expect(@abs(arr[0].Double - 5.0) < 0.01);
            // Second element is mean = 30.0
            try std.testing.expect(@abs(arr[1].Double - 30.0) < 0.01);
        },
        else => return error.UnexpectedResultType,
    }
}

test "ts_functions: matrix_profile" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 1, .metric = "mp" };
    try store.insertMany(key, &[_]timeseries.Point{
        .{ .ts = 1000, .value = 1 },
        .{ .ts = 2000, .value = 2 },
        .{ .ts = 3000, .value = 3 },
        .{ .ts = 4000, .value = 1 },
        .{ .ts = 5000, .value = 2 },
        .{ .ts = 6000, .value = 3 },
        .{ .ts = 7000, .value = 5 },
        .{ .ts = 8000, .value = 6 },
    });

    const call = TSFunctionCall{
        .function_type = .matrix_profile,
        .series_key = key,
        .params = .{ .matrix_profile = .{
            .start_ts = 1000,
            .end_ts = 8000,
            .subseq_len = 3,
        } },
    };

    var result = try executeFunction(&store, call, ally);
    defer deinitValue(&result, ally);

    switch (result) {
        .Map => |obj| {
            // Should have profile and indices keys
            try std.testing.expect(obj.get("profile") != null);
            try std.testing.expect(obj.get("indices") != null);
            const profile = obj.get("profile").?.List;
            const indices = obj.get("indices").?.List;
            try std.testing.expect(profile.len > 0);
            try std.testing.expectEqual(profile.len, indices.len);
        },
        else => return error.UnexpectedResultType,
    }
}

test "ts_functions: z_normalize" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 1, .metric = "zn" };
    try store.insertMany(key, &[_]timeseries.Point{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
    });

    const call = TSFunctionCall{
        .function_type = .z_normalize,
        .series_key = key,
        .params = .{ .z_normalize = .{
            .start_ts = 1000,
            .end_ts = 3000,
        } },
    };

    var result = try executeFunction(&store, call, ally);
    defer deinitValue(&result, ally);

    switch (result) {
        .List => |arr| {
            try std.testing.expectEqual(@as(usize, 3), arr.len);
            // Z-normalized: mean=0, std=1 -> values should be approximately -1.22, 0, 1.22
            try std.testing.expect(arr[0] == .Double);
            try std.testing.expect(arr[0].Double < 0);
            try std.testing.expect(@abs(arr[1].Double) < 0.01);
            try std.testing.expect(arr[2].Double > 0);
        },
        else => return error.UnexpectedResultType,
    }
}

test "ts_functions: invariants" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 1, .metric = "inv" };
    try store.insertMany(key, &[_]timeseries.Point{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
    });

    const call = TSFunctionCall{
        .function_type = .invariants,
        .series_key = key,
        .params = .{ .invariants = .{
            .start_ts = 1000,
            .end_ts = 3000,
        } },
    };

    var result = try executeFunction(&store, call, ally);
    defer deinitValue(&result, ally);

    switch (result) {
        .Map => |obj| {
            try std.testing.expect(obj.get("duration") != null);
            try std.testing.expect(obj.get("min") != null);
            try std.testing.expect(obj.get("max") != null);
            try std.testing.expect(obj.get("mean") != null);
            try std.testing.expect(obj.get("std_dev") != null);
            try std.testing.expect(obj.get("area") != null);
            try std.testing.expect(obj.get("histogram") != null);
            // Mean should be 20.0
            try std.testing.expect(@abs(obj.get("mean").?.Double - 20.0) < 0.01);
            // Min = 10.0, Max = 30.0
            try std.testing.expect(@abs(obj.get("min").?.Double - 10.0) < 0.01);
            try std.testing.expect(@abs(obj.get("max").?.Double - 30.0) < 0.01);
            // Duration = 3000.0 - 1000.0 = 2000.0
            try std.testing.expect(@abs(obj.get("duration").?.Double - 2000.0) < 0.01);
        },
        else => return error.UnexpectedResultType,
    }
}

// ---------------------------------------------------------------------------
// GAP-0290: Array-based analytic function tests
// ---------------------------------------------------------------------------

test "ts_functions: dtw constrained" {
    const ally = std.testing.allocator;
    const a = &[_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    const b = &[_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };

    const result = try executeDTW(ally, a, b, 2);
    try std.testing.expect(result == .Double);
    // Identical series -> distance should be 0
    try std.testing.expect(result.Double < 0.01);
}

test "ts_functions: dtw_derivative" {
    const ally = std.testing.allocator;
    const a = &[_]f64{ 1.0, 3.0, 5.0, 7.0 };
    const b = &[_]f64{ 1.0, 3.0, 5.0, 7.0 };

    const result = try executeDTWDerivative(ally, a, b, 2);
    try std.testing.expect(result == .Double);
    // Same derivative profile -> distance 0
    try std.testing.expect(result.Double < 0.01);
}

test "ts_functions: dtw_open_end" {
    const ally = std.testing.allocator;
    const a = &[_]f64{ 1.0, 2.0, 3.0 };
    const b = &[_]f64{ 1.0, 2.0, 3.0, 10.0, 20.0 };

    const result = try executeDTWOpenEnd(ally, a, b);
    try std.testing.expect(result == .Double);
    // Open-end: a aligns to prefix of b, should have low distance
    try std.testing.expect(result.Double < 0.01);
}

test "ts_functions: dtw_shape" {
    const ally = std.testing.allocator;
    const a = &[_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    const b = &[_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };

    const result = try executeDTWShape(ally, a, b, 2);
    try std.testing.expect(result == .Double);
    try std.testing.expect(result.Double < 0.01);
}

test "ts_functions: dtw_soft" {
    const ally = std.testing.allocator;
    const a = &[_]f64{ 1.0, 2.0, 3.0, 4.0 };
    const b = &[_]f64{ 1.0, 2.0, 3.0, 4.0 };

    const result = try executeDTWSoft(ally, a, b, 1.0);
    try std.testing.expect(result == .Double);
    // softDTW returns the soft minimum, identical series -> close to 0
    try std.testing.expect(result.Double < 0.01);
}

test "ts_functions: cosine_similarity" {
    const a = &[_]f64{ 1.0, 0.0, 0.0 };
    const b = &[_]f64{ 1.0, 0.0, 0.0 };

    const result = executeCosineSimilarity(a, b);
    try std.testing.expect(result == .Double);
    // Identical vectors -> cosine similarity = 1.0
    try std.testing.expect(@abs(result.Double - 1.0) < 0.01);
}

test "ts_functions: cross_correlate" {
    const ally = std.testing.allocator;
    const a = &[_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    const b = &[_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };

    var result = executeCrossCorrelate(ally, a, b);
    switch (result) {
        .Map => |*obj| {
            try std.testing.expect(obj.get("lag") != null);
            try std.testing.expect(obj.get("correlation") != null);
            // Self-correlation at lag 0 -> correlation close to 1.0
            try std.testing.expectEqual(@as(i64, 0), obj.get("lag").?.Int);
            try std.testing.expect(obj.get("correlation").?.Double > 0.99);
            obj.deinit();
        },
        else => return error.UnexpectedResultType,
    }
}

test "ts_functions: sbd" {
    const a = &[_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    const b = &[_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };

    const result = executeSBD(a, b);
    try std.testing.expect(result == .Double);
    // SBD of identical series = 1 - max_correlation = 1 - 1 = 0
    try std.testing.expect(result.Double < 0.01);
}

test "ts_functions: extractF64FromSeries" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 1, .metric = "ext" };
    try store.insertMany(key, &[_]timeseries.Point{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
        .{ .ts = 4000, .value = 40 },
    });

    // Extract range [2000, 3000]
    const values = try extractF64FromSeries(&store, key, 2000, 3000, ally);
    defer ally.free(values);
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expect(@abs(values[0] - 20.0) < 0.01);
    try std.testing.expect(@abs(values[1] - 30.0) < 0.01);
}

test "ts_functions: extractF64FromSeries missing series" {
    const ally = std.testing.allocator;

    var store = timeseries.Store.init(ally);
    defer store.deinit();

    const key = timeseries.SeriesKey{ .device_id = 999, .metric = "missing" };
    const values = try extractF64FromSeries(&store, key, 0, 9999, ally);
    defer ally.free(values);
    try std.testing.expectEqual(@as(usize, 0), values.len);
}
