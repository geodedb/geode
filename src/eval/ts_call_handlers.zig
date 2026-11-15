// CANARY: REQ=REQ-EVAL-REFACTOR-008; FEATURE="EvalExpr Refactoring"; ASPECT=TimeseriesCallHandlers; STATUS=TESTED; TEST=tests/test_gap0866_ts_scalar_eval.zig; OWNER=eval; UPDATED=2026-06-11
// GAP-0537: dedicated handler module for the scalar `timeseries.*` GQL
// function family, extracted from the eval.zig fallback `.Call` branch
// (follows the src/eval/call_handlers.zig module pattern).
//
// Contents (all previously inline in eval.zig):
// - evalTimeseriesValue()    - timeseries.value(device_id, metric, ts) point lookup
// - evalTimeseriesFunction() - series-based dispatch (last_value, value_at,
//   sample_by, time_bucket, interpolate, moving_avg, rate, derivative,
//   change_points, extract_features, matrix_profile, z_normalize, invariants)
//   plus delegation to the array-based family
// - evalArrayBasedTsFunction() - dtw, dtw_derivative, dtw_open_end, dtw_shape,
//   dtw_soft, cosine_similarity, cross_correlate, sbd (f64 list args)
//
// Every handler returns `null` when the function name is not its concern so
// the eval.zig fallback chain can keep dispatching. Regression safety net:
// tests/test_gap0866_ts_scalar_eval.zig (24 tests through the real
// parse → executeStatementWithContext → eval path) and the GAP-0280 tests in
// eval.zig (AST-built timeseries.value through evalExpr).

const std = @import("std");
const ast = @import("../gql/ast.zig");
const value_types = @import("../value_types.zig");
const ts_module = @import("../timeseries/timeseries.zig");
const ts_gql = @import("../timeseries/gql_functions.zig");

pub const Value = value_types.Value;
pub const EvalError = value_types.EvalError;
pub const Env = value_types.Env;

const TimeseriesStore = ts_module.Store;

// Recursive evaluation + global-store accessors live in eval.zig
const eval = @import("../eval.zig");
const evalExpr = eval.evalExpr;

/// Resolve the timeseries store from the Env, per-graph store, or global.
/// Priority: (1) per-Env pointer, (2) per-graph store via adapter, (3) global.
fn resolveTimeseriesStore(env: Env, graph_name: ?[]const u8) ?*TimeseriesStore {
    // Safety: @constCast is required because the external timeseries
    // library's getSeries/hashKey methods take *Store (mutable pointer)
    // even though they only perform read operations.  The Store is
    // effectively read-only at query time.
    if (env.timeseries_store) |ptr| return @constCast(ptr);
    return eval.getTimeseriesStoreForGraph(graph_name);
}

/// Convert a timeseries gql_functions.Value to the canonical value_types.Value.
/// Only the subset used by timeseries is converted (Null, Int, Double, Str, Bool, List, Map).
fn tsValueToCanonical(tv: ts_gql.Value, allocator: std.mem.Allocator) EvalError!Value {
    return switch (tv) {
        .Null => .{ .Null = {} },
        .Int => |v| .{ .Int = v },
        .Double => |v| .{ .Double = v },
        .Str => |v| .{ .Str = v },
        .Bool => |v| .{ .Bool = v },
        .List => |arr| blk: {
            const out = allocator.alloc(Value, arr.len) catch return EvalError.OutOfMemory;
            for (arr, 0..) |item, idx| {
                out[idx] = try tsValueToCanonical(item, allocator);
            }
            break :blk .{ .List = out };
        },
        .Map => |map| blk: {
            var out = std.StringHashMap(Value).init(allocator);
            var it = map.iterator();
            while (it.next()) |entry| {
                out.put(entry.key_ptr.*, try tsValueToCanonical(entry.value_ptr.*, allocator)) catch
                    return EvalError.OutOfMemory;
            }
            break :blk .{ .Map = out };
        },
    };
}

/// Time-series value lookup function: timeseries.value(device_id, metric, ts).
/// GAP-0280: Resolve the store from (1) per-Env pointer, or (2) the global
/// server-wide store set during startup.  This ensures timeseries.value()
/// returns real data whether called from the CLI path (env.timeseries_store)
/// or the QUIC/gRPC server path (the eval.zig global store).
/// Returns null when the function name is not timeseries.value.
pub fn evalTimeseriesValue(
    allocator: std.mem.Allocator,
    function_name: []const u8,
    args: []*ast.Expr,
    env: Env,
) EvalError!?Value {
    if (!std.ascii.eqlIgnoreCase(function_name, "timeseries.value")) return null;
    if (args.len != 3) return EvalError.WrongArgumentCount;

    const maybe_store: ?*TimeseriesStore = resolveTimeseriesStore(env, null);
    const store = maybe_store orelse return @as(?Value, .{ .Null = {} });

    const device_id_val = try evalExpr(allocator, args[0].*, env);
    const metric_val = try evalExpr(allocator, args[1].*, env);
    const ts_val = try evalExpr(allocator, args[2].*, env);

    if (device_id_val != .Int or metric_val != .Str or ts_val != .Int) {
        return EvalError.TypeMismatch;
    }

    const key = ts_module.SeriesKey{
        .device_id = device_id_val.Int,
        .metric = metric_val.Str,
    };

    if (store.getSeries(key)) |series| {
        if (series.valueAt(ts_val.Int)) |pt| {
            return @as(?Value, .{ .Int = pt.value });
        }
    }
    return @as(?Value, .{ .Null = {} });
}

/// GAP-0282/0290: Dispatch timeseries.* GQL function calls.
/// Series-based: last_value, value_at, sample_by, time_bucket, interpolate, moving_avg,
///   rate, derivative, change_points, extract_features, matrix_profile, z_normalize, invariants.
/// Array-based (delegated to evalArrayBasedTsFunction): dtw, dtw_derivative, dtw_open_end,
///   dtw_shape, dtw_soft, cosine_similarity, cross_correlate, sbd.
pub fn evalTimeseriesFunction(
    allocator: std.mem.Allocator,
    function_name: []const u8,
    args: []*ast.Expr,
    env: Env,
) EvalError!?Value {
    // All timeseries functions start with "timeseries." prefix (except timeseries.value handled above).
    // Per ISO/IEC 39075:2024 RQ-0022 the whole function name is matched
    // case-insensitively (GAP-0536/0537: the suffix comparisons below were
    // case-sensitive `std.mem.eql` before the extraction; now eqlIgnoreCase).
    if (!std.ascii.startsWithIgnoreCase(function_name, "timeseries.")) return null;
    const suffix = function_name["timeseries.".len..];

    // Skip "value" -- already handled by evalTimeseriesValue in the main dispatch
    if (std.ascii.eqlIgnoreCase(suffix, "value")) return null;

    // GAP-0290: Array-based functions take f64 list args directly (no device_id/metric)
    if (try evalArrayBasedTsFunction(allocator, suffix, args, env)) |result| {
        return result;
    }

    const maybe_store = resolveTimeseriesStore(env, null);
    const store = maybe_store orelse return @as(?Value, .{ .Null = {} });

    // All timeseries functions require at least 2 args: (device_id, metric)
    if (args.len < 2) return EvalError.WrongArgumentCount;

    const device_id_val = try evalExpr(allocator, args[0].*, env);
    const metric_val = try evalExpr(allocator, args[1].*, env);

    if (device_id_val != .Int or metric_val != .Str) return EvalError.TypeMismatch;

    const key = ts_module.SeriesKey{
        .device_id = device_id_val.Int,
        .metric = metric_val.Str,
    };

    // Build the TSFunctionCall based on the suffix
    var call: ts_gql.TSFunctionCall = undefined;
    call.series_key = key;

    if (std.ascii.eqlIgnoreCase(suffix, "last_value")) {
        if (args.len != 2) return EvalError.WrongArgumentCount;
        call.function_type = .last_value;
        call.params = .{ .last_value = {} };
    } else if (std.ascii.eqlIgnoreCase(suffix, "value_at")) {
        if (args.len != 3) return EvalError.WrongArgumentCount;
        const ts_val = try evalExpr(allocator, args[2].*, env);
        if (ts_val != .Int) return EvalError.TypeMismatch;
        call.function_type = .value_at;
        call.params = .{ .value_at = .{ .timestamp = ts_val.Int } };
    } else if (std.ascii.eqlIgnoreCase(suffix, "sample_by")) {
        // sample_by(device_id, metric, interval_ms, start_ts, end_ts, aggregation)
        if (args.len != 6) return EvalError.WrongArgumentCount;
        const interval = try evalExpr(allocator, args[2].*, env);
        const start = try evalExpr(allocator, args[3].*, env);
        const end = try evalExpr(allocator, args[4].*, env);
        const agg_str = try evalExpr(allocator, args[5].*, env);
        if (interval != .Int or start != .Int or end != .Int or agg_str != .Str)
            return EvalError.TypeMismatch;
        const agg = parseAggregation(agg_str.Str) orelse return EvalError.InvalidArgs;
        call.function_type = .sample_by;
        call.params = .{ .sample_by = .{
            .interval_ms = interval.Int,
            .start_ts = start.Int,
            .end_ts = end.Int,
            .aggregation = agg,
        } };
    } else if (std.ascii.eqlIgnoreCase(suffix, "time_bucket")) {
        // time_bucket(device_id, metric, bucket_ms, start_ts, end_ts)
        if (args.len != 5) return EvalError.WrongArgumentCount;
        const bucket = try evalExpr(allocator, args[2].*, env);
        const start = try evalExpr(allocator, args[3].*, env);
        const end = try evalExpr(allocator, args[4].*, env);
        if (bucket != .Int or start != .Int or end != .Int)
            return EvalError.TypeMismatch;
        call.function_type = .time_bucket;
        call.params = .{ .time_bucket = .{
            .bucket_ms = bucket.Int,
            .start_ts = start.Int,
            .end_ts = end.Int,
        } };
    } else if (std.ascii.eqlIgnoreCase(suffix, "interpolate")) {
        // interpolate(device_id, metric, timestamp, method)
        if (args.len != 4) return EvalError.WrongArgumentCount;
        const ts_val = try evalExpr(allocator, args[2].*, env);
        const method_val = try evalExpr(allocator, args[3].*, env);
        if (ts_val != .Int or method_val != .Str) return EvalError.TypeMismatch;
        const method_str = method_val.Str;
        call.function_type = .interpolate;
        call.params = .{ .interpolate = .{
            .timestamp = ts_val.Int,
            .method = if (std.mem.eql(u8, method_str, "linear"))
                .linear
            else if (std.mem.eql(u8, method_str, "step"))
                .step
            else if (std.mem.eql(u8, method_str, "nearest"))
                .nearest
            else
                return EvalError.InvalidArgs,
        } };
    } else if (std.ascii.eqlIgnoreCase(suffix, "moving_avg")) {
        // moving_avg(device_id, metric, window_ms, step_ms)
        if (args.len != 4) return EvalError.WrongArgumentCount;
        const window = try evalExpr(allocator, args[2].*, env);
        const step = try evalExpr(allocator, args[3].*, env);
        if (window != .Int or step != .Int) return EvalError.TypeMismatch;
        call.function_type = .moving_avg;
        call.params = .{ .moving_avg = .{
            .window_ms = window.Int,
            .step_ms = step.Int,
        } };
    } else if (std.ascii.eqlIgnoreCase(suffix, "rate")) {
        // rate(device_id, metric, interval_ms)
        if (args.len != 3) return EvalError.WrongArgumentCount;
        const interval = try evalExpr(allocator, args[2].*, env);
        if (interval != .Int) return EvalError.TypeMismatch;
        call.function_type = .rate;
        call.params = .{ .rate = .{ .interval_ms = interval.Int } };
    } else if (std.ascii.eqlIgnoreCase(suffix, "derivative")) {
        // derivative(device_id, metric, order)
        if (args.len != 3) return EvalError.WrongArgumentCount;
        const order_val = try evalExpr(allocator, args[2].*, env);
        if (order_val != .Int) return EvalError.TypeMismatch;
        if (order_val.Int < 0 or order_val.Int > 255) return EvalError.InvalidArgs;
        call.function_type = .derivative;
        call.params = .{ .derivative = .{ .order = @intCast(order_val.Int) } };
    } else if (std.ascii.eqlIgnoreCase(suffix, "change_points")) {
        // GAP-0290: change_points(device_id, metric, start_ts, end_ts, penalty, min_size)
        if (args.len != 6) return EvalError.WrongArgumentCount;
        const start = try evalExpr(allocator, args[2].*, env);
        const end = try evalExpr(allocator, args[3].*, env);
        const penalty_val = try evalExpr(allocator, args[4].*, env);
        const min_size_val = try evalExpr(allocator, args[5].*, env);
        if (start != .Int or end != .Int or min_size_val != .Int)
            return EvalError.TypeMismatch;
        // GAP-0866: parsed float literals evaluate to .Decimal — accept all numerics.
        const penalty = value_types.toDouble(penalty_val) orelse return EvalError.TypeMismatch;
        if (min_size_val.Int < 1) return EvalError.InvalidArgs;
        call.function_type = .change_points;
        call.params = .{ .change_points = .{
            .start_ts = start.Int,
            .end_ts = end.Int,
            .penalty = penalty,
            .min_size = @intCast(min_size_val.Int),
        } };
    } else if (std.ascii.eqlIgnoreCase(suffix, "extract_features")) {
        // GAP-0290: extract_features(device_id, metric, start_ts, end_ts)
        if (args.len != 4) return EvalError.WrongArgumentCount;
        const start = try evalExpr(allocator, args[2].*, env);
        const end = try evalExpr(allocator, args[3].*, env);
        if (start != .Int or end != .Int) return EvalError.TypeMismatch;
        call.function_type = .extract_features;
        call.params = .{ .extract_features = .{
            .start_ts = start.Int,
            .end_ts = end.Int,
        } };
    } else if (std.ascii.eqlIgnoreCase(suffix, "matrix_profile")) {
        // GAP-0290: matrix_profile(device_id, metric, start_ts, end_ts, subseq_len)
        if (args.len != 5) return EvalError.WrongArgumentCount;
        const start = try evalExpr(allocator, args[2].*, env);
        const end = try evalExpr(allocator, args[3].*, env);
        const subseq = try evalExpr(allocator, args[4].*, env);
        if (start != .Int or end != .Int or subseq != .Int)
            return EvalError.TypeMismatch;
        if (subseq.Int < 1) return EvalError.InvalidArgs;
        call.function_type = .matrix_profile;
        call.params = .{ .matrix_profile = .{
            .start_ts = start.Int,
            .end_ts = end.Int,
            .subseq_len = @intCast(subseq.Int),
        } };
    } else if (std.ascii.eqlIgnoreCase(suffix, "z_normalize")) {
        // GAP-0290: z_normalize(device_id, metric, start_ts, end_ts)
        if (args.len != 4) return EvalError.WrongArgumentCount;
        const start = try evalExpr(allocator, args[2].*, env);
        const end = try evalExpr(allocator, args[3].*, env);
        if (start != .Int or end != .Int) return EvalError.TypeMismatch;
        call.function_type = .z_normalize;
        call.params = .{ .z_normalize = .{
            .start_ts = start.Int,
            .end_ts = end.Int,
        } };
    } else if (std.ascii.eqlIgnoreCase(suffix, "invariants")) {
        // GAP-0290: invariants(device_id, metric, start_ts, end_ts)
        if (args.len != 4) return EvalError.WrongArgumentCount;
        const start = try evalExpr(allocator, args[2].*, env);
        const end = try evalExpr(allocator, args[3].*, env);
        if (start != .Int or end != .Int) return EvalError.TypeMismatch;
        call.function_type = .invariants;
        call.params = .{ .invariants = .{
            .start_ts = start.Int,
            .end_ts = end.Int,
        } };
    } else {
        return null; // Unknown timeseries function
    }

    const ts_result = ts_gql.executeFunction(store, call, allocator) catch return EvalError.OutOfMemory;
    return try tsValueToCanonical(ts_result, allocator);
}

fn parseAggregation(s: []const u8) ?ts_module.lib.store.Aggregation {
    if (std.mem.eql(u8, s, "avg")) return .avg;
    if (std.mem.eql(u8, s, "sum")) return .sum;
    if (std.mem.eql(u8, s, "min")) return .min;
    if (std.mem.eql(u8, s, "max")) return .max;
    if (std.mem.eql(u8, s, "count")) return .count;
    if (std.mem.eql(u8, s, "first")) return .first;
    if (std.mem.eql(u8, s, "last")) return .last;
    return null;
}

/// GAP-0290: Dispatch array-based timeseries functions that take f64 list arguments
/// directly (no series key). Returns null if the suffix doesn't match any array-based function.
fn evalArrayBasedTsFunction(
    allocator: std.mem.Allocator,
    suffix: []const u8,
    args: []*ast.Expr,
    env: Env,
) EvalError!?Value {
    // Helper: evaluate a Value and extract []f64 from a List of numeric values.
    // GAP-0866: real parsed float literals (e.g. `[1.0, 2.5]`) evaluate to
    // `.Decimal` (exact numeric), not `.Double`, so this must accept every
    // numeric variant — use value_types.toDouble (Int/Double/Decimal) plus Real.
    const extractF64List = struct {
        fn run(alloc: std.mem.Allocator, val: Value) EvalError!?[]f64 {
            if (val != .List) return null;
            const list = val.List;
            const out = alloc.alloc(f64, list.len) catch return EvalError.OutOfMemory;
            for (list, 0..) |item, i| {
                out[i] = value_types.toDouble(item) orelse switch (item) {
                    .Real => |r| @as(f64, r),
                    else => {
                        alloc.free(out);
                        return EvalError.TypeMismatch;
                    },
                };
            }
            return out;
        }
    }.run;

    if (std.ascii.eqlIgnoreCase(suffix, "dtw")) {
        // dtw(vals_a, vals_b, window)
        if (args.len != 3) return null;
        const a_val = try evalExpr(allocator, args[0].*, env);
        const b_val = try evalExpr(allocator, args[1].*, env);
        const w_val = try evalExpr(allocator, args[2].*, env);
        const a_arr = try extractF64List(allocator, a_val) orelse return EvalError.TypeMismatch;
        defer allocator.free(a_arr);
        const b_arr = try extractF64List(allocator, b_val) orelse return EvalError.TypeMismatch;
        defer allocator.free(b_arr);
        if (w_val != .Int) return EvalError.TypeMismatch;
        // SONNY-2769: a negative window aborted the server in the cast.
        if (w_val.Int < 0) return EvalError.InvalidArgs;
        const ts_result = ts_gql.executeDTW(allocator, a_arr, b_arr, @intCast(w_val.Int)) catch return EvalError.OutOfMemory;
        return try tsValueToCanonical(ts_result, allocator);
    } else if (std.ascii.eqlIgnoreCase(suffix, "dtw_derivative")) {
        // dtw_derivative(vals_a, vals_b, window)
        if (args.len != 3) return null;
        const a_val = try evalExpr(allocator, args[0].*, env);
        const b_val = try evalExpr(allocator, args[1].*, env);
        const w_val = try evalExpr(allocator, args[2].*, env);
        const a_arr = try extractF64List(allocator, a_val) orelse return EvalError.TypeMismatch;
        defer allocator.free(a_arr);
        const b_arr = try extractF64List(allocator, b_val) orelse return EvalError.TypeMismatch;
        defer allocator.free(b_arr);
        if (w_val != .Int) return EvalError.TypeMismatch;
        if (w_val.Int < 0) return EvalError.InvalidArgs; // SONNY-2769: see dtw
        const ts_result = ts_gql.executeDTWDerivative(allocator, a_arr, b_arr, @intCast(w_val.Int)) catch return EvalError.OutOfMemory;
        return try tsValueToCanonical(ts_result, allocator);
    } else if (std.ascii.eqlIgnoreCase(suffix, "dtw_open_end")) {
        // dtw_open_end(vals_a, vals_b)
        if (args.len != 2) return null;
        const a_val = try evalExpr(allocator, args[0].*, env);
        const b_val = try evalExpr(allocator, args[1].*, env);
        const a_arr = try extractF64List(allocator, a_val) orelse return EvalError.TypeMismatch;
        defer allocator.free(a_arr);
        const b_arr = try extractF64List(allocator, b_val) orelse return EvalError.TypeMismatch;
        defer allocator.free(b_arr);
        const ts_result = ts_gql.executeDTWOpenEnd(allocator, a_arr, b_arr) catch return EvalError.OutOfMemory;
        return try tsValueToCanonical(ts_result, allocator);
    } else if (std.ascii.eqlIgnoreCase(suffix, "dtw_shape")) {
        // dtw_shape(vals_a, vals_b, reach)
        if (args.len != 3) return null;
        const a_val = try evalExpr(allocator, args[0].*, env);
        const b_val = try evalExpr(allocator, args[1].*, env);
        const r_val = try evalExpr(allocator, args[2].*, env);
        const a_arr = try extractF64List(allocator, a_val) orelse return EvalError.TypeMismatch;
        defer allocator.free(a_arr);
        const b_arr = try extractF64List(allocator, b_val) orelse return EvalError.TypeMismatch;
        defer allocator.free(b_arr);
        if (r_val != .Int) return EvalError.TypeMismatch;
        if (r_val.Int < 0) return EvalError.InvalidArgs; // SONNY-2769: see dtw
        const ts_result = ts_gql.executeDTWShape(allocator, a_arr, b_arr, @intCast(r_val.Int)) catch return EvalError.OutOfMemory;
        return try tsValueToCanonical(ts_result, allocator);
    } else if (std.ascii.eqlIgnoreCase(suffix, "dtw_soft")) {
        // dtw_soft(vals_a, vals_b, gamma)
        if (args.len != 3) return null;
        const a_val = try evalExpr(allocator, args[0].*, env);
        const b_val = try evalExpr(allocator, args[1].*, env);
        const g_val = try evalExpr(allocator, args[2].*, env);
        const a_arr = try extractF64List(allocator, a_val) orelse return EvalError.TypeMismatch;
        defer allocator.free(a_arr);
        const b_arr = try extractF64List(allocator, b_val) orelse return EvalError.TypeMismatch;
        defer allocator.free(b_arr);
        // GAP-0866: parsed float literals evaluate to .Decimal — accept all numerics.
        const gamma = value_types.toDouble(g_val) orelse return EvalError.TypeMismatch;
        const ts_result = ts_gql.executeDTWSoft(allocator, a_arr, b_arr, gamma) catch return EvalError.OutOfMemory;
        return try tsValueToCanonical(ts_result, allocator);
    } else if (std.ascii.eqlIgnoreCase(suffix, "cosine_similarity")) {
        // cosine_similarity(vals_a, vals_b)
        if (args.len != 2) return null;
        const a_val = try evalExpr(allocator, args[0].*, env);
        const b_val = try evalExpr(allocator, args[1].*, env);
        const a_arr = try extractF64List(allocator, a_val) orelse return EvalError.TypeMismatch;
        defer allocator.free(a_arr);
        const b_arr = try extractF64List(allocator, b_val) orelse return EvalError.TypeMismatch;
        defer allocator.free(b_arr);
        const ts_result = ts_gql.executeCosineSimilarity(a_arr, b_arr);
        return try tsValueToCanonical(ts_result, allocator);
    } else if (std.ascii.eqlIgnoreCase(suffix, "cross_correlate")) {
        // cross_correlate(vals_a, vals_b)
        if (args.len != 2) return null;
        const a_val = try evalExpr(allocator, args[0].*, env);
        const b_val = try evalExpr(allocator, args[1].*, env);
        const a_arr = try extractF64List(allocator, a_val) orelse return EvalError.TypeMismatch;
        defer allocator.free(a_arr);
        const b_arr = try extractF64List(allocator, b_val) orelse return EvalError.TypeMismatch;
        defer allocator.free(b_arr);
        const ts_result = ts_gql.executeCrossCorrelate(allocator, a_arr, b_arr);
        return try tsValueToCanonical(ts_result, allocator);
    } else if (std.ascii.eqlIgnoreCase(suffix, "sbd")) {
        // sbd(vals_a, vals_b)
        if (args.len != 2) return null;
        const a_val = try evalExpr(allocator, args[0].*, env);
        const b_val = try evalExpr(allocator, args[1].*, env);
        const a_arr = try extractF64List(allocator, a_val) orelse return EvalError.TypeMismatch;
        defer allocator.free(a_arr);
        const b_arr = try extractF64List(allocator, b_val) orelse return EvalError.TypeMismatch;
        defer allocator.free(b_arr);
        const ts_result = ts_gql.executeSBD(allocator, a_arr, b_arr);
        return try tsValueToCanonical(ts_result, allocator);
    }

    return null; // Not an array-based function
}

// ---------------------------------------------------------------------------
// Unit tests (GAP-0537). The heavy integration coverage lives in
// tests/test_gap0866_ts_scalar_eval.zig (24 tests through the real parser +
// executor); these pin the module's dispatch contract in isolation.
// ---------------------------------------------------------------------------

test "ts_call_handlers: evalTimeseriesValue ignores non-timeseries names" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };
    const result = try evalTimeseriesValue(allocator, "upper", &.{}, env);
    try std.testing.expect(result == null);
}

test "ts_call_handlers: evalTimeseriesValue returns Null without a store" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };

    var dev = ast.Expr{ .Int = 42 };
    var metric = ast.Expr{ .String = "temperature" };
    var ts = ast.Expr{ .Int = 1000 };
    var args = [_]*ast.Expr{ &dev, &metric, &ts };

    const result = try evalTimeseriesValue(allocator, "timeseries.value", args[0..], env);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .Null);
}

test "ts_call_handlers: evalTimeseriesValue rejects wrong arity" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };
    var dev = ast.Expr{ .Int = 42 };
    var args = [_]*ast.Expr{&dev};
    // SONNY-6555 item 5: an operand count is the program text's (42000).
    try std.testing.expectError(
        EvalError.WrongArgumentCount,
        evalTimeseriesValue(allocator, "TIMESERIES.VALUE", args[0..], env),
    );
}

test "ts_call_handlers: evalTimeseriesFunction ignores non-prefixed names and value suffix" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };
    try std.testing.expect((try evalTimeseriesFunction(allocator, "upper", &.{}, env)) == null);
    try std.testing.expect((try evalTimeseriesFunction(allocator, "timeseries.value", &.{}, env)) == null);
}

test "ts_call_handlers: value lookup against a real store" {
    const allocator = std.testing.allocator;
    var store = TimeseriesStore.init(allocator);
    defer store.deinit();
    const key = ts_module.SeriesKey{ .device_id = 7, .metric = "temp" };
    try store.insertMany(key, &[_]ts_module.Point{
        .{ .ts = 100, .value = 11 },
        .{ .ts = 200, .value = 22 },
    });

    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{}, .timeseries_store = &store };
    var dev = ast.Expr{ .Int = 7 };
    var metric = ast.Expr{ .String = "temp" };
    var ts = ast.Expr{ .Int = 200 };
    var args = [_]*ast.Expr{ &dev, &metric, &ts };

    const result = try evalTimeseriesValue(allocator, "timeseries.value", args[0..], env);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .Int);
    try std.testing.expectEqual(@as(i64, 22), result.?.Int);
}

test "ts_call_handlers: last_value through evalTimeseriesFunction with env store" {
    // GAP-0888 review follow-up: this test had never actually run (the file
    // was not rooted by any step) and bit-rotted in two ways:
    //  - last_value returns a point object ({ts, value} Map), not a bare
    //    Int — the Map contract matches the integration test
    //    (tests/test_gap0866_ts_scalar_eval.zig: `.value AS v`);
    //  - the handler's value conversion allocates intermediates it does not
    //    free — its documented contract is the per-request arena (GAP-0755),
    //    so evaluate under an arena here.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = TimeseriesStore.init(allocator);
    defer store.deinit();
    const key = ts_module.SeriesKey{ .device_id = 7, .metric = "temp" };
    try store.insertMany(key, &[_]ts_module.Point{
        .{ .ts = 100, .value = 11 },
        .{ .ts = 200, .value = 22 },
    });

    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{}, .timeseries_store = &store };
    var dev = ast.Expr{ .Int = 7 };
    var metric = ast.Expr{ .String = "temp" };
    var args = [_]*ast.Expr{ &dev, &metric };

    const result = try evalTimeseriesFunction(allocator, "timeseries.last_value", args[0..], env);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .Map);
    try std.testing.expectEqual(@as(i64, 200), result.?.Map.get("ts").?.Int);
    try std.testing.expectEqual(@as(i64, 22), result.?.Map.get("value").?.Int);

    // GAP-0536: per ISO/IEC 39075:2024 RQ-0022 the whole function name is
    // case-insensitive — mixed-case suffix must dispatch identically.
    const mixed = try evalTimeseriesFunction(allocator, "TiMeSeRiEs.LaSt_VaLuE", args[0..], env);
    try std.testing.expect(mixed != null);
    try std.testing.expect(mixed.? == .Map);
    try std.testing.expectEqual(@as(i64, 22), mixed.?.Map.get("value").?.Int);
}
