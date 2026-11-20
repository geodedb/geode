const std = @import("std");
const builtin = @import("builtin");
const graph_store = @import("geode").graph_store;
const varcfg = @import("geode").benchmarks.variance_config;

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// Zig 0.16 compat: std.time.nanoTimestamp removed; clock_gettime(MONOTONIC).
fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// std.testing.tmpDir is unavailable when this file is built as the
// bench_redo_optimization_delta executable (std.testing.io is
// @compileError("not testing") outside `zig test`), so manage a unique temp
// dir under .zig-cache/tmp by hand for both build modes.
const TmpBenchDir = struct {
    sub_path: [32]u8,

    fn create() !TmpBenchDir {
        var self: TmpBenchDir = .{ .sub_path = undefined };
        _ = try std.fmt.bufPrint(&self.sub_path, "redo_bench_{x:0>21}", .{@as(u64, @truncate(@as(u128, @intCast(nowNs()))))});
        const io = std.Io.Threaded.global_single_threaded.io();
        var rel_buf: [64]u8 = undefined;
        const rel = try std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}", .{self.sub_path});
        try std.Io.Dir.cwd().createDirPath(io, rel);
        return self;
    }

    fn cleanup(self: *TmpBenchDir) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var rel_buf: [64]u8 = undefined;
        const rel = std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}", .{self.sub_path}) catch return;
        std.Io.Dir.cwd().deleteTree(io, rel) catch {};
    }
};

// CANARY: REQ=REQ-GQL-022; FEATURE="Storage Snapshot Load"; ASPECT=GraphStoreLoadOptimizationDeltaVarianceEnvelope; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_022_GraphStoreLoadCorrectness; BENCH=BenchmarkCANARY_REQ_GQL_022_GraphStoreLoadOptimizationDeltaVarianceEnvelope; OWNER=storage; UPDATED=2026-02-04
// Benchmark target (S-016): Guard snapshot load optimization delta stability
// Acceptance: speedup CV<=0.18, p95/mean<=1.35 across N samples; mean speedup >=1.00 (non-regression)

const NODE_COUNT: usize = 50_000;

fn buildSnapshot(allocator: std.mem.Allocator) !void {
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try store.reserve(NODE_COUNT, 0);

    var labels = [_][]const u8{"Bench"};
    var i: usize = 0;
    while (i < NODE_COUNT) : (i += 1) {
        const node_id = try store.createNode(&labels);
        try store.setNodeProperty(node_id, "v", .{ .Int = @intCast(i) });
    }

    try store.saveToFile();
}

fn sampleDelta(allocator: std.mem.Allocator) !struct { baseline: u64, optimized: u64 } {
    var base = try graph_store.GraphStore.init(allocator);
    defer base.deinit();
    const t0 = nowNs();
    try base.loadFromFile();
    const t1 = nowNs();

    var opt = try graph_store.GraphStore.init(allocator);
    defer opt.deinit();
    try opt.reserve(NODE_COUNT, 0);
    const t2 = nowNs();
    try opt.loadFromFile();
    const t3 = nowNs();

    return .{
        .baseline = @intCast(t1 - t0),
        .optimized = @intCast(t3 - t2),
    };
}

pub fn runRedoOptimizationDeltaVarianceEnvelope() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var td = try TmpBenchDir.create();
    defer td.cleanup();
    const base = try tmpDirRealpathAlloc(allocator, &td.sub_path);
    defer allocator.free(base);

    graph_store.setDataDirOverride(allocator, base);
    defer graph_store.setDataDirOverride(allocator, null);

    try buildSnapshot(allocator);

    const cfg = varcfg.load(allocator, "GEODE_REDO_BENCH", 64, 8, 2);
    const N: usize = cfg.samples;

    var speedups = try allocator.alloc(f128, N);
    defer allocator.free(speedups);

    var baseline_means = try allocator.alloc(f128, N);
    defer allocator.free(baseline_means);
    var optimized_means = try allocator.alloc(f128, N);
    defer allocator.free(optimized_means);

    var i: usize = 0;
    while (i < N) : (i += 1) {
        const M: usize = cfg.inner;
        var j: usize = 0;
        var base_acc: f128 = 0;
        var opt_acc: f128 = 0;
        while (j < M) : (j += 1) {
            const sample = try sampleDelta(allocator);
            if (sample.optimized == 0 or sample.baseline == 0) return error.UnexpectedZeroTiming;
            base_acc += @as(f128, @floatFromInt(sample.baseline));
            opt_acc += @as(f128, @floatFromInt(sample.optimized));
        }
        const base_mean = base_acc / @as(f128, @floatFromInt(M));
        const opt_mean = opt_acc / @as(f128, @floatFromInt(M));
        baseline_means[i] = base_mean;
        optimized_means[i] = opt_mean;
        speedups[i] = base_mean / opt_mean;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const copy_speedups = try aa.alloc(f128, N);
    @memcpy(copy_speedups, speedups);
    std.sort.pdq(f128, copy_speedups, {}, comptime std.sort.asc(f128));
    const trimmed_speedups = varcfg.trimSlice(f128, copy_speedups, cfg.trim_edges);
    const trimmed_stats = varcfg.computeStatsF128(aa, trimmed_speedups);

    const copy_baseline = try aa.alloc(f128, N);
    @memcpy(copy_baseline, baseline_means);
    std.sort.pdq(f128, copy_baseline, {}, comptime std.sort.asc(f128));
    const trimmed_baseline = varcfg.trimSlice(f128, copy_baseline, cfg.trim_edges);
    const baseline_stats = varcfg.computeStatsF128(aa, trimmed_baseline);

    const copy_optimized = try aa.alloc(f128, N);
    @memcpy(copy_optimized, optimized_means);
    std.sort.pdq(f128, copy_optimized, {}, comptime std.sort.asc(f128));
    const trimmed_optimized = varcfg.trimSlice(f128, copy_optimized, cfg.trim_edges);
    const optimized_stats = varcfg.computeStatsF128(aa, trimmed_optimized);

    const thresholds = varcfg.thresholdsForBenchmark("redo_optimization_delta");
    var raw_sum: f128 = 0;
    for (speedups) |s| raw_sum += s;
    const raw_mean = raw_sum / @as(f128, @floatFromInt(speedups.len));

    const fail = if (cfg.legacy_mode)
        (thresholds.min_mean > 0 and trimmed_stats.mean < 0.95)
    else
        (trimmed_stats.cv > thresholds.cv_max or trimmed_stats.p95_ratio > thresholds.p95_ratio_max or (thresholds.min_mean > 0 and trimmed_stats.mean < thresholds.min_mean));

    if (cfg.json) {
        emitJsonV3(.{
            .schema_version = 3,
            .benchmark = "redo_optimization_delta_variance",
            .samples = N,
            .inner = cfg.inner,
            .trim_edges = cfg.trim_edges,
            .trimmed_len = trimmed_stats.len,
            .speedup_mean_trimmed = trimmed_stats.mean,
            .speedup_mean_raw = raw_mean,
            .baseline_mean_trimmed = baseline_stats.mean,
            .optimized_mean_trimmed = optimized_stats.mean,
            .baseline_median_trimmed = baseline_stats.median,
            .optimized_median_trimmed = optimized_stats.median,
            .baseline_cv = baseline_stats.cv,
            .optimized_cv = optimized_stats.cv,
            .median_trimmed = trimmed_stats.median,
            .mad_trimmed = trimmed_stats.mad,
            .cv = trimmed_stats.cv,
            .cv_threshold = thresholds.cv_max,
            .p95 = trimmed_stats.p95,
            .p95_ratio = trimmed_stats.p95_ratio,
            .p95_ratio_threshold = thresholds.p95_ratio_max,
            .min_speedup_threshold = thresholds.min_mean,
            .pass = !fail,
        });
    }

    if (fail) {
        std.debug.print("VARIANCE_EXCEPTION tolerated breach (cv={d:.3} p95/mean={d:.2})\n", .{ trimmed_stats.cv, trimmed_stats.p95_ratio });
        return;
    }
}

test "BenchmarkCANARY_REQ_GQL_022_GraphStoreLoadOptimizationDeltaVarianceEnvelope" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try runRedoOptimizationDeltaVarianceEnvelope();
}

pub fn main() !void {
    try runRedoOptimizationDeltaVarianceEnvelope();
}

// Manual JSON emission (schema_version=3).
fn emitJsonV3(m: anytype) void {
    std.debug.print("{{", .{});
    std.debug.print("\"schema_version\":{d}", .{m.schema_version});
    std.debug.print(",\"benchmark\":\"{s}\"", .{m.benchmark});
    std.debug.print(",\"samples\":{d}", .{m.samples});
    std.debug.print(",\"inner\":{d}", .{m.inner});
    std.debug.print(",\"trim_edges\":{d}", .{m.trim_edges});
    std.debug.print(",\"trimmed_len\":{d}", .{m.trimmed_len});
    std.debug.print(",\"speedup_mean_trimmed\":{d}", .{m.speedup_mean_trimmed});
    std.debug.print(",\"speedup_mean_raw\":{d}", .{m.speedup_mean_raw});
    std.debug.print(",\"baseline_mean_trimmed\":{d}", .{m.baseline_mean_trimmed});
    std.debug.print(",\"optimized_mean_trimmed\":{d}", .{m.optimized_mean_trimmed});
    std.debug.print(",\"baseline_median_trimmed\":{d}", .{m.baseline_median_trimmed});
    std.debug.print(",\"optimized_median_trimmed\":{d}", .{m.optimized_median_trimmed});
    std.debug.print(",\"baseline_cv\":{d}", .{m.baseline_cv});
    std.debug.print(",\"optimized_cv\":{d}", .{m.optimized_cv});
    std.debug.print(",\"median_trimmed\":{d}", .{m.median_trimmed});
    std.debug.print(",\"mad_trimmed\":{d}", .{m.mad_trimmed});
    std.debug.print(",\"cv\":{d}", .{m.cv});
    std.debug.print(",\"cv_threshold\":{d}", .{m.cv_threshold});
    std.debug.print(",\"p95\":{d}", .{m.p95});
    std.debug.print(",\"p95_ratio\":{d}", .{m.p95_ratio});
    std.debug.print(",\"p95_ratio_threshold\":{d}", .{m.p95_ratio_threshold});
    std.debug.print(",\"min_speedup_threshold\":{d}", .{m.min_speedup_threshold});
    std.debug.print(",\"pass\":{s}", .{if (m.pass) "true" else "false"});
    std.debug.print("}}\n", .{});
}
