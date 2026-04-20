const std = @import("std");
const schema = @import("bench_schema");

pub const DatasetSize = enum {
    small, // 500 nodes, no edges
    medium, // 2000 nodes + 8000 edges
    large, // 10000 nodes + 30000 edges

    pub fn label(self: DatasetSize) []const u8 {
        return @tagName(self);
    }

    pub fn nodeCount(self: DatasetSize) usize {
        return switch (self) {
            .small => 500,
            .medium => 2000,
            .large => 10000,
        };
    }

    pub fn edgesPerNode(self: DatasetSize) usize {
        return switch (self) {
            .small => 0,
            .medium => 4,
            .large => 3,
        };
    }
};

pub const QueryScenarioSpec = struct {
    name: []const u8,
    query: []const u8,
    dataset_size: DatasetSize = .small,
    variant: []const u8 = "default",
    iterations: usize = 7,
    warmup_iterations: usize = 1,
    /// Optional parameter injector. If null, the bench uses a fixed seed
    /// value (int 42 for point/one/two/fan_out shapes).
    param_fn: ?*const fn (iteration: usize) i64 = null,
};

pub const QueryResultRow = struct {
    git_sha: []const u8,
    run_timestamp_unix_s: i64,
    zig_version: []const u8,
    os: []const u8,
    arch: []const u8,
    cpu: []const u8,
    scenario_name: []const u8,
    variant: []const u8 = "default",
    dataset_size: []const u8,
    iterations: usize,
    warmup_iterations: usize,
    wall_time_ns_median: u64,
    wall_time_ns_stddev: u64 = 0,
    throughput_ops_per_sec: f64,
    throughput_stddev_ops_per_sec: f64 = 0,
    parse_ns_per_op_p50: u64 = 0,
    plan_ns_per_op_p50: u64 = 0,
    execute_ns_per_op_p50: u64 = 0,
    materialize_ns_per_op_p50: u64 = 0,
    row_count_p50: u64 = 0,
    plan_cache_hits: u64 = 0,
    plan_cache_misses: u64 = 0,
    alloc_count_per_op: u64 = 0,
    alloc_bytes_per_op: u64 = 0,
    peak_rss_delta_bytes: i64 = 0,
};

/// Expand one QueryResultRow into N generic ResultRow records (one per
/// named measurement) so `zig build compare-bench` can apply its prefix-
/// based noise gate per measurement. The scenario_name/variant get a
/// `/<dataset_size>` suffix to keep rows unique when we run the same
/// query across multiple dataset sizes.
pub fn expand(allocator: std.mem.Allocator, rows: []const QueryResultRow) ![]schema.ResultRow {
    var out = try std.ArrayList(schema.ResultRow).initCapacity(allocator, rows.len * 10);
    errdefer out.deinit(allocator);
    for (rows) |row| {
        const name_suffix = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ row.scenario_name, row.dataset_size });
        // Add one entry per measurement.
        const measurements = [_]struct { m: []const u8, v: f64, stddev: f64 }{
            .{ .m = "throughput_ops_per_sec", .v = row.throughput_ops_per_sec, .stddev = row.throughput_stddev_ops_per_sec },
            .{ .m = "wall_time_ns", .v = @floatFromInt(row.wall_time_ns_median), .stddev = @floatFromInt(row.wall_time_ns_stddev) },
            .{ .m = "latency_parse_ns_p50", .v = @floatFromInt(row.parse_ns_per_op_p50), .stddev = 0 },
            .{ .m = "latency_plan_ns_p50", .v = @floatFromInt(row.plan_ns_per_op_p50), .stddev = 0 },
            .{ .m = "latency_execute_ns_p50", .v = @floatFromInt(row.execute_ns_per_op_p50), .stddev = 0 },
            .{ .m = "latency_materialize_ns_p50", .v = @floatFromInt(row.materialize_ns_per_op_p50), .stddev = 0 },
            .{ .m = "alloc_bytes_per_op", .v = @floatFromInt(row.alloc_bytes_per_op), .stddev = 0 },
            .{ .m = "peak_rss_delta_bytes", .v = @floatFromInt(row.peak_rss_delta_bytes), .stddev = 0 },
        };
        for (measurements) |m| {
            try out.append(allocator, .{
                .git_sha = row.git_sha,
                .run_timestamp_unix_s = row.run_timestamp_unix_s,
                .zig_version = row.zig_version,
                .os = row.os,
                .arch = row.arch,
                .cpu = row.cpu,
                .scenario_name = name_suffix,
                .variant = row.variant,
                .measurement = m.m,
                .value = m.v,
                .value_stddev = m.stddev,
                .sample_count = row.iterations,
                .wall_time_ns = row.wall_time_ns_median,
            });
        }
    }
    return try out.toOwnedSlice(allocator);
}

pub fn freeExpanded(allocator: std.mem.Allocator, rows: []schema.ResultRow) void {
    // scenario_name entries were allocPrint'd in expand() — one allocation per
    // input QueryResultRow, shared across all measurement rows for that input.
    // Free each unique pointer exactly once by tracking previously freed ptrs.
    var prev: ?[*]const u8 = null;
    for (rows) |row| {
        if (prev == null or prev.? != row.scenario_name.ptr) {
            allocator.free(row.scenario_name);
            prev = row.scenario_name.ptr;
        }
    }
    allocator.free(rows);
}

/// Compute median + stddev over a slice of ns samples. Caller sorts the
/// slice in-place; this function assumes it's sorted ascending.
pub fn medianAndStddev(samples_sorted: []u64) struct { median: u64, stddev: u64 } {
    if (samples_sorted.len == 0) return .{ .median = 0, .stddev = 0 };
    const mid = samples_sorted.len / 2;
    const median: u64 = if (samples_sorted.len % 2 == 0)
        (samples_sorted[mid - 1] + samples_sorted[mid]) / 2
    else
        samples_sorted[mid];
    var sum_sq: u128 = 0;
    for (samples_sorted) |s| {
        const diff: i128 = @as(i128, s) - @as(i128, median);
        sum_sq += @intCast(diff * diff);
    }
    const variance = sum_sq / samples_sorted.len;
    const stddev: u64 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(variance))));
    return .{ .median = median, .stddev = stddev };
}
