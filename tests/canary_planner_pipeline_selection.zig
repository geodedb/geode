const std = @import("std");
const perf_gate = @import("perf_gate");

// Zig 0.16 compat helpers for test code
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}
fn compat_sleep(ns: u64) void {
    var req: std.posix.timespec = .{ .sec = 0, .nsec = @intCast(ns) };
    var rem: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.nanosleep(@ptrCast(&req), @ptrCast(&rem));
    } else {
        _ = std.c.nanosleep(&req, &rem);
    }
}

const geode = @import("geode");
const pipeline = geode.planner_pipeline;

// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanSelectionPipelineAdoption; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_PlanSelectionPipelineAdoption; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanSelectionPipelineVarianceEnvelope; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_024_PlanSelectionPipelineAdoption; BENCH=BenchmarkCANARY_REQ_GQL_024_PlanSelectionPipelineVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_024_PlanSelectionPipelineAdoption" {
    const q = pipeline.defaultEmptyQuery();
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var res = try pipeline.planQuerySelectBest(gpa.allocator(), q, .{ .max_plans = 128, .enable_prune = true, .prune_factor = 2.0 });
    defer res.deinit();
    try std.testing.expect(res.best != null and res.total_candidates > 0);
}

const PipelineBench = struct {
    fn select(_: *PipelineBench) !usize {
        const q = pipeline.defaultEmptyQuery();
        var res = try pipeline.planQuerySelectBest(perf_gate.bench_allocator, q, .{ .max_plans = 256, .enable_prune = true, .prune_factor = 2.5 });
        defer res.deinit();
        return res.total_candidates;
    }
};

test "BenchmarkCANARY_REQ_GQL_024_PlanSelectionPipelineVarianceEnvelope" {
    // SONNY-2439: batched samples from the production allocator, robust
    // statistics (median, IQR) -- see tests/perf_gate.zig.
    var bench: PipelineBench = .{};
    var samples: [48]f64 = undefined;
    _ = try perf_gate.timeBatch(&bench, PipelineBench.select, 16);
    try perf_gate.sampleBatches(&bench, PipelineBench.select, 16, &samples);
    const r = perf_gate.robust(&samples);
    // Perf claims go through the shared gate (SONNY-2394): reported unless
    // GEODE_PERF_GATES=enforce (SONNY-2439) -- see tests/perf_gate.zig.
    // Correctness assertions in this file are not gated.
    try perf_gate.robustEnvelope("pipeline plan selection", r, 0.30, 2.55);
}
