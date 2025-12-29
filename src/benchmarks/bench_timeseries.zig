const std = @import("std");
const eval = @import("../eval.zig");
const types = @import("../value_types.zig");
const ts = @import("../timeseries/timeseries.zig");
const ast = @import("../gql/ast.zig");

const TestConfig = struct {
    num_points: usize,
    num_queries: usize,
    name: []const u8,
};

fn runBenchmark(config: TestConfig, allocator: std.mem.Allocator) !void {
    std.debug.print("\n{s}:\n", .{config.name});
    std.debug.print("  Configuration: {} points, {} queries\n", .{ config.num_points, config.num_queries });

    // Initialize Store
    var store = ts.Store.init(allocator);
    defer store.deinit();

    const device_id: i64 = 1001;
    const metric_name = "temperature";
    const key = ts.SeriesKey{ .device_id = device_id, .metric = metric_name };

    // 1. Benchmark Ingestion
    std.debug.print("  Generating data...\n", .{});
    var points = try allocator.alloc(ts.Point, config.num_points);
    defer allocator.free(points);

    const start_ts: i64 = 1600000000;
    var i: usize = 0;
    while (i < config.num_points) : (i += 1) {
        points[i] = .{ .ts = start_ts + @as(i64, @intCast(i)), .value = 20 + @as(i64, @intCast(i % 100)) };
    }

    std.debug.print("  Ingesting data...\n", .{});
    const ingest_start = std.time.nanoTimestamp();
    try store.insertMany(key, points);
    const ingest_end = std.time.nanoTimestamp();
    const ingest_ms = @as(f64, @floatFromInt(ingest_end - ingest_start)) / 1_000_000.0;
    const ingest_rate = @as(f64, @floatFromInt(config.num_points)) / (ingest_ms / 1000.0);

    std.debug.print("  Ingestion: {d:.2} ms ({d:.2} points/sec)\n", .{ ingest_ms, ingest_rate });

    // 2. Benchmark Query (GQL eval)
    std.debug.print("  Benchmarking GQL evaluation (timeseries.value)...\n", .{});

    // Construct AST Expression: timeseries.value(1001, "temperature", $ts)
    // We will update $ts in the Env for each query.

    // Arguments
    const arg0 = ast.Expr{ .Int = device_id };
    const arg1 = ast.Expr{ .String = metric_name };
    // Param for timestamp
    const param_name = "ts";
    const arg2 = ast.Expr{ .Param = param_name };

    // Call
    // const callee = ast.Expr{ .Ident = ast.Ident{ .orig = "timeseries.value", .loc = .{} } };
    // Wait, eval.zig expects function name in a specific way.
    // Line 757: .Ident => |ident| ident.orig
    const func_ident = ast.Ident{ .orig = "timeseries.value", .loc = .{} };
    const func_expr = ast.Expr{ .Ident = func_ident };
    const args_list = [_]*const ast.Expr{ &arg0, &arg1, &arg2 };
    const call_expr = ast.Expr{ .Call = .{ .callee = &func_expr, .args = &args_list } };

    // Setup Environment
    const p_names = [_][]const u8{"ts"};
    var p_vals = [_]types.Value{.{ .Int = 0 }}; // Value placeholder

    const query_start = std.time.nanoTimestamp();

    var q: usize = 0;
    var hits: usize = 0;
    while (q < config.num_queries) : (q += 1) {
        // Query random timestamps within range
        const query_ts = start_ts + @as(i64, @intCast(q % config.num_points));
        p_vals[0] = types.Value{ .Int = query_ts };

        const env = types.Env{
            .names = &.{},
            .values = &.{},
            .param_names = &p_names,
            .param_values = &p_vals,
            .allocator = allocator,
            .timeseries_store = &store, // Pass the store!
        };

        const result = eval.evalExpr(allocator, call_expr, env) catch |err| {
            std.debug.print("Eval error: {}\n", .{err});
            return err;
        };

        if (result != .Null) hits += 1;
    }

    const query_end = std.time.nanoTimestamp();
    const query_ms = @as(f64, @floatFromInt(query_end - query_start)) / 1_000_000.0;
    const query_rate = @as(f64, @floatFromInt(config.num_queries)) / (query_ms / 1000.0);

    std.debug.print("  Query: {d:.2} ms ({d:.2} queries/sec) (Hits: {})\n", .{ query_ms, query_rate, hits });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const configs = [_]TestConfig{
        .{ .num_points = 100_000, .num_queries = 100_000, .name = "Medium Load" },
        .{ .num_points = 1_000_000, .num_queries = 100_000, .name = "Large Load (1M points)" },
    };

    for (configs) |config| {
        try runBenchmark(config, allocator);
    }
}
