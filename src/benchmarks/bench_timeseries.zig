const std = @import("std");
const geode = @import("geode");
const eval = geode.eval;
const value_types = geode.value_types;
const ts = geode.timeseries;
const ast = geode.ast;

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

    // 2. Benchmark Query -- direct Store API (not eval, to avoid heavy AST construction)
    std.debug.print("  Benchmarking Store.valueBefore queries...\n", .{});

    const query_start = std.time.nanoTimestamp();

    var q: usize = 0;
    var hits: usize = 0;
    while (q < config.num_queries) : (q += 1) {
        const query_ts = start_ts + @as(i64, @intCast(q % config.num_points));
        if (store.valueBefore(key, query_ts)) |_| {
            hits += 1;
        }
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
