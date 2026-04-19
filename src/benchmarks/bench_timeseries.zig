const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const schema = @import("bench_schema");
const eval = geode.eval;
const value_types = geode.value_types;
const ts = geode.timeseries;
const ast = geode.ast;

// Zig 0.16 compat: std.time.nanoTimestamp removed; use clock_gettime(MONOTONIC).
fn nowNs() i128 {
    var tsval: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &tsval);
    return @as(i128, tsval.sec) * 1_000_000_000 + @as(i128, tsval.nsec);
}

// Zig 0.16 compat: std.time.timestamp removed; use clock_gettime(REALTIME).
fn nowUnixS() i64 {
    var tsval: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.REALTIME, &tsval);
    return @intCast(tsval.sec);
}

// Median-of-6-after-warmup pattern (mirrors zig/thread-pool/benchmarks/common.zig):
//   - run 7 iterations per (config, measurement) pair
//   - discard iteration 0 as warmup
//   - sort the remaining 6 ascending
//   - median = (arr[2] + arr[3]) / 2
//   - stddev computed over the same 6 samples
const ITERATIONS: usize = 7;
const WARMUP: usize = 1;
const KEPT: usize = ITERATIONS - WARMUP; // 6

const TestConfig = struct {
    num_points: usize,
    num_queries: usize,
    name: []const u8, // human-readable for stdout mode
    slug: []const u8, // stable slug used in scenario_name (JSON mode)
};

const IterResult = struct {
    ingest_rate: f64, // points/sec
    query_rate: f64, // queries/sec
    ingest_ns: u64,
    query_ns: u64,
};

fn runOneIteration(config: TestConfig, allocator: std.mem.Allocator) !IterResult {
    var store = ts.Store.init(allocator);
    defer store.deinit();

    const device_id: i64 = 1001;
    const metric_name = "temperature";
    const key = ts.SeriesKey{ .device_id = device_id, .metric = metric_name };

    const points = try allocator.alloc(ts.Point, config.num_points);
    defer allocator.free(points);

    const start_ts: i64 = 1600000000;
    var i: usize = 0;
    while (i < config.num_points) : (i += 1) {
        points[i] = .{ .ts = start_ts + @as(i64, @intCast(i)), .value = 20 + @as(i64, @intCast(i % 100)) };
    }

    const ingest_start = nowNs();
    try store.insertMany(key, points);
    const ingest_end = nowNs();
    const ingest_ns: u64 = @intCast(ingest_end - ingest_start);
    const ingest_ms = @as(f64, @floatFromInt(ingest_ns)) / 1_000_000.0;
    const ingest_rate = @as(f64, @floatFromInt(config.num_points)) / (ingest_ms / 1000.0);

    const query_start = nowNs();
    var q: usize = 0;
    var hits: usize = 0;
    while (q < config.num_queries) : (q += 1) {
        const query_ts = start_ts + @as(i64, @intCast(q % config.num_points));
        if (store.valueBefore(key, query_ts)) |_| hits += 1;
    }
    const query_end = nowNs();
    const query_ns: u64 = @intCast(query_end - query_start);
    const query_ms = @as(f64, @floatFromInt(query_ns)) / 1_000_000.0;
    const query_rate = @as(f64, @floatFromInt(config.num_queries)) / (query_ms / 1000.0);

    // Swallow `hits` into the result path so the optimizer can't drop it.
    if (hits == std.math.maxInt(usize)) std.debug.print("!", .{});

    return .{
        .ingest_rate = ingest_rate,
        .query_rate = query_rate,
        .ingest_ns = ingest_ns,
        .query_ns = query_ns,
    };
}

fn cmpF64Asc(_: void, a: f64, b: f64) bool {
    return a < b;
}

fn medianAndStddev(samples: []f64) struct { median: f64, stddev: f64 } {
    std.mem.sort(f64, samples, {}, cmpF64Asc);
    // Median for even-length slice = mean of middle two.
    const mid_hi = samples.len / 2;
    const mid_lo = mid_hi - 1;
    const median = (samples[mid_lo] + samples[mid_hi]) / 2.0;

    var sum: f64 = 0;
    for (samples) |x| sum += x;
    const mean = sum / @as(f64, @floatFromInt(samples.len));
    var sq_sum: f64 = 0;
    for (samples) |x| {
        const d = x - mean;
        sq_sum += d * d;
    }
    const variance = sq_sum / @as(f64, @floatFromInt(samples.len));
    return .{ .median = median, .stddev = @sqrt(variance) };
}

fn runBenchmark(
    config: TestConfig,
    allocator: std.mem.Allocator,
    output_path: ?[]const u8,
    rows: *std.ArrayList(schema.ResultRow),
    common: RowCommon,
) !void {
    const human = output_path == null;
    if (human) {
        std.debug.print("\n{s}:\n", .{config.name});
        std.debug.print("  Configuration: {} points, {} queries\n", .{ config.num_points, config.num_queries });
        std.debug.print("  Running {d} iterations (discarding 1 warmup)...\n", .{ITERATIONS});
    }

    var ingest_samples: [KEPT]f64 = undefined;
    var query_samples: [KEPT]f64 = undefined;
    var total_ingest_ns: u64 = 0;
    var total_query_ns: u64 = 0;

    var iter: usize = 0;
    while (iter < ITERATIONS) : (iter += 1) {
        const r = try runOneIteration(config, allocator);
        if (iter >= WARMUP) {
            const slot = iter - WARMUP;
            ingest_samples[slot] = r.ingest_rate;
            query_samples[slot] = r.query_rate;
            total_ingest_ns += r.ingest_ns;
            total_query_ns += r.query_ns;
        }
        if (human) {
            const tag = if (iter < WARMUP) "warmup" else "sample";
            std.debug.print(
                "    [{s} {d}/{d}] ingest={d:.2} pts/s  query={d:.2} q/s\n",
                .{ tag, iter + 1, ITERATIONS, r.ingest_rate, r.query_rate },
            );
        }
    }

    const ingest_stats = medianAndStddev(&ingest_samples);
    const query_stats = medianAndStddev(&query_samples);

    if (human) {
        std.debug.print(
            "  Ingest median: {d:.2} pts/s  (stddev {d:.2}, n={d})\n",
            .{ ingest_stats.median, ingest_stats.stddev, KEPT },
        );
        std.debug.print(
            "  Query  median: {d:.2} q/s    (stddev {d:.2}, n={d})\n",
            .{ query_stats.median, query_stats.stddev, KEPT },
        );
    }

    // Emit JSON rows regardless of mode; writer decides whether to persist.
    const ingest_scenario = try std.fmt.allocPrint(allocator, "timeseries_ingest_{s}", .{config.slug});
    const query_scenario = try std.fmt.allocPrint(allocator, "timeseries_query_{s}", .{config.slug});
    // Strings are owned by the caller's arena-ish allocator. We deliberately
    // do NOT free them here — the ArrayList outlives the function and the
    // allocator is the short-lived DebugAllocator inside main().

    try rows.append(allocator, .{
        .git_sha = common.git_sha,
        .run_timestamp_unix_s = common.run_timestamp_unix_s,
        .zig_version = common.zig_version,
        .os = common.os,
        .arch = common.arch,
        .cpu = common.cpu,
        .scenario_name = ingest_scenario,
        .measurement = "throughput_points_per_sec",
        .value = ingest_stats.median,
        .value_stddev = ingest_stats.stddev,
        .sample_count = KEPT,
        .wall_time_ns = total_ingest_ns,
    });
    try rows.append(allocator, .{
        .git_sha = common.git_sha,
        .run_timestamp_unix_s = common.run_timestamp_unix_s,
        .zig_version = common.zig_version,
        .os = common.os,
        .arch = common.arch,
        .cpu = common.cpu,
        .scenario_name = query_scenario,
        .measurement = "throughput_queries_per_sec",
        .value = query_stats.median,
        .value_stddev = query_stats.stddev,
        .sample_count = KEPT,
        .wall_time_ns = total_query_ns,
    });
}

const RowCommon = struct {
    git_sha: []const u8,
    run_timestamp_unix_s: i64,
    zig_version: []const u8,
    os: []const u8,
    arch: []const u8,
    cpu: []const u8,
};

fn getEnvOr(allocator: std.mem.Allocator, name: []const u8, fallback: []const u8) ![]const u8 {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);
    if (std.c.getenv(name_z)) |ptr| {
        const slice = std.mem.span(ptr);
        if (slice.len == 0) return try allocator.dupe(u8, fallback);
        return try allocator.dupe(u8, slice);
    }
    return try allocator.dupe(u8, fallback);
}

pub fn main(proc_init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // --- argv parsing: --output <path> -------------------------------------
    const raw_argv = proc_init.args.vector;
    var output_path: ?[]const u8 = null;
    var idx: usize = 1;
    while (idx < raw_argv.len) : (idx += 1) {
        const a = std.mem.span(raw_argv[idx]);
        if (std.mem.eql(u8, a, "--output")) {
            if (idx + 1 >= raw_argv.len) {
                std.debug.print("bench-timeseries: --output requires a path argument\n", .{});
                return error.InvalidArgs;
            }
            idx += 1;
            output_path = std.mem.span(raw_argv[idx]);
        } else if (std.mem.startsWith(u8, a, "--output=")) {
            output_path = a["--output=".len..];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                "bench-timeseries [--output <path>]\n" ++
                    "  --output PATH   write ResultDocument JSON to PATH\n" ++
                    "                  (default: human-readable stdout)\n",
                .{},
            );
            return;
        }
    }

    // --- shared ResultRow fields ------------------------------------------
    const git_sha = try getEnvOr(allocator, "GEODE_BENCH_GIT_SHA", "unknown");
    defer allocator.free(git_sha);
    const cpu = try getEnvOr(allocator, "GEODE_BENCH_CPU", "unknown");
    defer allocator.free(cpu);

    const common = RowCommon{
        .git_sha = git_sha,
        .run_timestamp_unix_s = nowUnixS(),
        .zig_version = builtin.zig_version_string,
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .cpu = cpu,
    };

    const configs = [_]TestConfig{
        .{ .num_points = 100_000, .num_queries = 100_000, .name = "Medium Load", .slug = "100k" },
        .{ .num_points = 1_000_000, .num_queries = 100_000, .name = "Large Load (1M points)", .slug = "1m" },
    };

    // Note: 7 iterations of the 1M-point config takes ~10-30s on a typical
    // dev laptop (ReleaseFast). That's fine — this is a perf harness, not
    // a unit test. Debug mode is noticeably slower; prefer -Doptimize=ReleaseFast.
    var rows: std.ArrayList(schema.ResultRow) = .empty;
    defer rows.deinit(allocator);

    // Track allocPrint'd scenario_name strings so we can free them after
    // JSON serialisation. Their lifetime has to outlive writeDocument.
    var owned_scenarios: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_scenarios.items) |s| allocator.free(s);
        owned_scenarios.deinit(allocator);
    }

    for (configs) |config| {
        const before = rows.items.len;
        try runBenchmark(config, allocator, output_path, &rows, common);
        // scenario_name strings were allocated with allocPrint inside
        // runBenchmark; take ownership for cleanup.
        for (rows.items[before..]) |r| {
            // Only store the ones we actually allocated (both measurements).
            // Safe cast: we know these were allocPrint'd []u8.
            try owned_scenarios.append(allocator, @constCast(r.scenario_name));
        }
    }

    if (output_path) |path| {
        const doc = schema.ResultDocument{
            .generated_at_unix_s = nowUnixS(),
            .rows = rows.items,
        };
        const io = std.Io.Threaded.global_single_threaded.io();
        try schema.writeDocument(allocator, io, path, doc);
        std.debug.print("bench-timeseries: wrote {d} rows to {s}\n", .{ rows.items.len, path });
    }
}
