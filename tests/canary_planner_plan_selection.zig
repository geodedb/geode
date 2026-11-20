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

// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanSelectionIntegration; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_PlanSelectionIntegration; BENCH=BenchmarkCANARY_REQ_GQL_024_PlanSelectionVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-024; FEATURE="Cost Based Optimizer"; ASPECT=PlanSelectionVarianceEnvelope; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_024_PlanSelectionIntegration; BENCH=BenchmarkCANARY_REQ_GQL_024_PlanSelectionVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_024_PlanSelectionIntegration" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Build small plan with join so we have >1 candidate
    const leaf = enumerator_mod.LogicalPlan{ .op = .scan, .children = &[_]enumerator_mod.LogicalPlan{} };
    var join_children: [2]enumerator_mod.LogicalPlan = .{ leaf, leaf };
    const root = enumerator_mod.LogicalPlan{ .op = .join, .children = join_children[0..] };

    var enumr = enumerator_mod.PlanEnumerator.init(alloc, .{ .max_plans = 32 });
    defer enumr.deinit();
    var buf = std.ArrayList(enumerator_mod.CandidatePlan).empty;
    const best = try enumr.selectBestUnmanaged(root, alloc, &buf) orelse return error.UnexpectedEmptyEnumeration;
    // Expect cost non-negative and enumerate produced at least 2 plans
    try std.testing.expect(best.cost >= 0);
    try std.testing.expect(buf.items.len >= 2);
    buf.deinit(alloc);
}

const SelectBench = struct {
    root: enumerator_mod.LogicalPlan,
    alloc: std.mem.Allocator,

    fn select(self: *SelectBench) !f64 {
        var enumr = enumerator_mod.PlanEnumerator.init(self.alloc, .{ .max_plans = 128 });
        defer enumr.deinit();
        var buf = std.ArrayList(enumerator_mod.CandidatePlan).empty;
        defer buf.deinit(self.alloc);
        const best = try enumr.selectBestUnmanaged(self.root, self.alloc, &buf) orelse return error.UnexpectedEmptyEnumeration;
        return best.cost;
    }
};

test "BenchmarkCANARY_REQ_GQL_024_PlanSelectionVarianceEnvelope" {
    // SONNY-2439: batched samples (ns per selection) from the production
    // allocator, robust statistics (median, IQR) -- see tests/perf_gate.zig.
    const alloc = perf_gate.bench_allocator;
    // Construct deeper plan tree for enumeration
    const leaf = enumerator_mod.LogicalPlan{ .op = .scan, .children = &[_]enumerator_mod.LogicalPlan{} };
    var c1: [1]enumerator_mod.LogicalPlan = .{leaf};
    const proj = enumerator_mod.LogicalPlan{ .op = .project, .children = c1[0..] };
    var c2: [1]enumerator_mod.LogicalPlan = .{leaf};
    const filt = enumerator_mod.LogicalPlan{ .op = .filter, .children = c2[0..] };
    var c3: [2]enumerator_mod.LogicalPlan = .{ proj, filt };
    const join1 = enumerator_mod.LogicalPlan{ .op = .join, .children = c3[0..] };
    var c4: [2]enumerator_mod.LogicalPlan = .{ join1, leaf };
    const join2 = enumerator_mod.LogicalPlan{ .op = .join, .children = c4[0..] };

    var bench: SelectBench = .{ .root = join2, .alloc = alloc };
    var samples: [64]f64 = undefined;
    _ = try perf_gate.timeBatch(&bench, SelectBench.select, 16);
    try perf_gate.sampleBatches(&bench, SelectBench.select, 16, &samples);
    const r = perf_gate.robust(&samples);
    // Perf claims go through the shared gate (SONNY-2394): reported unless
    // GEODE_PERF_GATES=enforce (SONNY-2439) -- see tests/perf_gate.zig.
    // Correctness assertions in this file are not gated.
    try perf_gate.robustEnvelope("plan selection", r, 0.30, 2.55);
}
