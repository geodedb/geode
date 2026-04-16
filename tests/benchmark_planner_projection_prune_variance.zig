const std = @import("std");
const pipeline = @import("../src/planner/pipeline.zig");
const path_cache_mod = @import("../src/planner/path_cache.zig");

// CANARY: REQ=REQ-GQL-021; FEATURE="Query Planner"; ASPECT=PlannerProjectionPruneVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_021_PlannerProjectionPruneVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

fn stats(values: []u64) struct { mean: f64, stddev: f64, cv: f64, p95: u64 } {
    if (values.len == 0) return .{ .mean = 0, .stddev = 0, .cv = 0, .p95 = 0 };
    var sum: f128 = 0;
    for (values) |v| sum += @as(f128, @floatFromInt(v));
    const mean_f128 = sum / @as(f128, @floatFromInt(values.len));
    var var_acc: f128 = 0;
    for (values) |v| {
        const diff = @as(f128, @floatFromInt(v)) - mean_f128;
        var_acc += diff * diff;
    }
    const variance = if (values.len > 1) var_acc / @as(f128, @floatFromInt(values.len)) else 0;
    const stddev = @as(f64, @floatCast(@sqrt(variance)));
    const mean_cast = @as(f64, @floatCast(mean_f128));
    const tmp = std.heap.page_allocator.alloc(u64, values.len) catch unreachable;
    defer std.heap.page_allocator.free(tmp);
    std.mem.copy(u64, tmp, values);
    std.sort.pdq(u64, tmp, {}, comptime std.sort.asc(u64));
    const p95 = tmp[@min(tmp.len - 1, (tmp.len * 95) / 100)];
    return .{ .mean = mean_cast, .stddev = stddev, .cv = if (mean_cast == 0) 0 else stddev / mean_cast, .p95 = p95 };
}

fn runSamples(allocator: std.mem.Allocator, runs: usize) ![]u64 {
    var cache = try path_cache_mod.PathCache.init(allocator, 16);
    defer cache.deinit();
    var proj = try allocator.alloc(u64, runs);
    errdefer allocator.free(proj);
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        const q = switch (i & 3) {
            0 => "RETURN 1 AS x",
            1 => "MATCH (a)--(b) RETURN a",
            2 => "MATCH (a)--(b)--(c) RETURN b",
            else => "MATCH (x) RETURN x",
        };
        const res = try pipeline.runPipeline(allocator, .{}, &cache, q);
        proj[i] = res.timings.projection_prune_ns;
    }
    return proj;
}

inline fn checkVariance(label: []const u8, st: anytype) !void {
    if (st.cv > 0.22 or (@as(f128, @floatFromInt(st.p95)) > @as(f128, @floatCast(st.mean)) * 2.55)) {
        std.debug.print("VARIANCE_FAIL {s} cv={:.4} p95={} mean={:.2}\n", .{ label, st.cv, st.p95, st.mean });
        return error.VarianceExceeded;
    }
    std.debug.print("VARIANCE_OK {s} cv={:.4} p95={} mean={:.2}\n", .{ label, st.cv, st.p95, st.mean });
}

test "BenchmarkCANARY_REQ_GQL_021_PlannerProjectionPruneVarianceEnvelope" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const samples = try runSamples(gpa.allocator(), 64);
    defer gpa.allocator().free(samples);
    const st = stats(samples);
    try checkVariance("PlannerProjectionPruneVarianceEnvelope", st);
}
