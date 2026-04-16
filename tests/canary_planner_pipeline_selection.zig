const std = @import("std");

// Zig 0.16 compat helpers for test code
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}
fn compat_sleep(ns: u64) void {
    const req = std.os.linux.timespec{ .sec = 0, .nsec = @intCast(ns) };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

const geode = @import("geode");
const pipeline = geode.planner_pipeline;

// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanSelectionPipelineAdoption; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_PlanSelectionPipelineAdoption; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanSelectionPipelineVarianceEnvelope; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_024_PlanSelectionPipelineAdoption; BENCH=BenchmarkCANARY_REQ_GQL_024_PlanSelectionPipelineVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_024_PlanSelectionPipelineAdoption" {
    const q = pipeline.defaultEmptyQuery();
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const res = try pipeline.planQuerySelectBest(gpa.allocator(), q, .{ .max_plans = 128, .enable_prune = true, .prune_factor = 2.0 });
    try std.testing.expect(res.best != null and res.total_candidates > 0);
}

test "BenchmarkCANARY_REQ_GQL_024_PlanSelectionPipelineVarianceEnvelope" {
    const q = pipeline.defaultEmptyQuery();
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const iterations: usize = 48;
    var samples = try gpa.allocator().alloc(u64, iterations);
    defer gpa.allocator().free(samples);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = compat_nanoTimestamp();
        _ = try pipeline.planQuerySelectBest(gpa.allocator(), q, .{ .max_plans = 256, .enable_prune = true, .prune_factor = 2.5 });
        const end = compat_nanoTimestamp();
        samples[i] = @as(u64, @intCast(end - start));
    }
    var s: f128 = 0;
    for (samples) |v| s += @as(f128, @floatFromInt(v));
    const mean = s / @as(f128, @floatFromInt(samples.len));
    var var_acc: f128 = 0;
    for (samples) |v| {
        const d = @as(f128, @floatFromInt(v)) - mean;
        var_acc += d * d;
    }
    const variance = var_acc / @as(f128, @floatFromInt(samples.len));
    var scratch = std.heap.page_allocator.dupe(u64, samples) catch unreachable;
    defer std.heap.page_allocator.free(scratch);
    const rank = (samples.len * 95) / 100;
    var r: usize = 0;
    while (r <= rank) : (r += 1) {
        var min_i = r;
        var j: usize = r + 1;
        while (j < samples.len) : (j += 1) {
            if (scratch[j] < scratch[min_i]) min_i = j;
        }
        if (min_i != r) {
            const tmp = scratch[r];
            scratch[r] = scratch[min_i];
            scratch[min_i] = tmp;
        }
    }
    const p95 = @as(f128, @floatFromInt(scratch[rank]));
    const cv = std.math.sqrt(variance) / mean;
    const p95_mean = p95 / mean;
    try std.testing.expect(cv <= 0.22 and p95_mean <= 2.55);
}
