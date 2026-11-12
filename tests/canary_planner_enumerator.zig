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

const enumerator_mod = @import("planner_enumerator");

// Promote IMPL to TESTED after this test passes.
// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanEnumerationEngine; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_PlanEnumerationEngine; BENCH=BenchmarkCANARY_REQ_GQL_024_PlanEnumerationVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

test "TestCANARY_REQ_GQL_024_PlanEnumerationEngine" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const leaf = enumerator_mod.LogicalPlan{ .op = .scan, .children = &[_]enumerator_mod.LogicalPlan{} };
    var join_children: [2]enumerator_mod.LogicalPlan = .{ leaf, leaf };
    const root = enumerator_mod.LogicalPlan{ .op = .join, .children = join_children[0..] };

    var enumerator = enumerator_mod.PlanEnumerator.init(alloc, .{});
    defer enumerator.deinit();
    var plans = std.ArrayList(enumerator_mod.CandidatePlan).empty;
    // SONNY-2394: this defer used to appear twice (double free -> GPF).
    defer plans.deinit(alloc);
    try plans.ensureTotalCapacity(alloc, 16);
    try enumerator.enumerateUnmanaged(root, alloc, &plans);
    try std.testing.expect(plans.items.len >= 2); // original + swapped
    // check distinct signatures
    try std.testing.expect(plans.items[0].signature != plans.items[1].signature);
}

// Variance envelope benchmark (structural enumeration time jitter)
// We keep this simple: run enumeration multiple times, capture duration stats; enforce CV and p95/mean thresholds.
// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanEnumerationVarianceEnvelope; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_024_PlanEnumerationEngine; BENCH=BenchmarkCANARY_REQ_GQL_024_PlanEnumerationVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21
const EnumBench = struct {
    root: enumerator_mod.LogicalPlan,
    alloc: std.mem.Allocator,

    fn enumerate(self: *EnumBench) !usize {
        var enumerator = enumerator_mod.PlanEnumerator.init(self.alloc, .{ .max_plans = 512 });
        defer enumerator.deinit();
        var plans = std.ArrayList(enumerator_mod.CandidatePlan).empty;
        defer plans.deinit(self.alloc);
        try plans.ensureTotalCapacity(self.alloc, 32);
        try enumerator.enumerateUnmanaged(self.root, self.alloc, &plans);
        return plans.items.len;
    }
};

test "BenchmarkCANARY_REQ_GQL_024_PlanEnumerationVarianceEnvelope" {
    // SONNY-2439: batched samples (ns per enumeration) from the production
    // allocator, robust statistics (median, IQR) -- see tests/perf_gate.zig.
    const alloc = perf_gate.bench_allocator;

    // Build a modest tree: join(project(scan, scan), aggregate(filter(scan))) depth ~3
    const scan_leaf = enumerator_mod.LogicalPlan{ .op = .scan, .children = &[_]enumerator_mod.LogicalPlan{} };
    var proj_children: [1]enumerator_mod.LogicalPlan = .{scan_leaf};
    const project_node = enumerator_mod.LogicalPlan{ .op = .project, .children = proj_children[0..] };
    var right_filter_child: [1]enumerator_mod.LogicalPlan = .{scan_leaf};
    const filter_node = enumerator_mod.LogicalPlan{ .op = .filter, .children = right_filter_child[0..] };
    var agg_children: [1]enumerator_mod.LogicalPlan = .{filter_node};
    const agg_node = enumerator_mod.LogicalPlan{ .op = .aggregate, .children = agg_children[0..] };
    var top_join_children: [2]enumerator_mod.LogicalPlan = .{ project_node, agg_node };
    const root = enumerator_mod.LogicalPlan{ .op = .join, .children = top_join_children[0..] };

    var bench: EnumBench = .{ .root = root, .alloc = alloc };
    var samples: [64]f64 = undefined;
    _ = try perf_gate.timeBatch(&bench, EnumBench.enumerate, 16);
    try perf_gate.sampleBatches(&bench, EnumBench.enumerate, 16, &samples);
    const r = perf_gate.robust(&samples);
    // Perf claims go through the shared gate (SONNY-2394): reported unless
    // GEODE_PERF_GATES=enforce (SONNY-2439) -- see tests/perf_gate.zig.
    // Correctness assertions in this file are not gated.
    try perf_gate.robustEnvelope("plan enumeration", r, 0.30, 2.55);
}
