const std = @import("std");

// Zig 0.16 compat helpers for test code
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
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
    var buf = std.ArrayList(enumerator_mod.CandidatePlan).empty;
    const best = try enumr.selectBestUnmanaged(root, alloc, &buf) orelse return error.UnexpectedEmptyEnumeration;
    // Expect cost non-negative and enumerate produced at least 2 plans
    try std.testing.expect(best.cost >= 0);
    try std.testing.expect(buf.items.len >= 2);
    buf.deinit(alloc);
}

test "BenchmarkCANARY_REQ_GQL_024_PlanSelectionVarianceEnvelope" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
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

    const iterations: usize = 64;
    var samples = try alloc.alloc(u64, iterations);
    defer alloc.free(samples);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var enumr = enumerator_mod.PlanEnumerator.init(alloc, .{ .max_plans = 128 });
        var buf = std.ArrayList(enumerator_mod.CandidatePlan).empty;
        const start = compat_nanoTimestamp();
        _ = try enumr.selectBestUnmanaged(join2, alloc, &buf);
        const end = compat_nanoTimestamp();
        samples[i] = @as(u64, @intCast(end - start));
        buf.deinit(alloc);
    }
    var sum: f128 = 0;
    for (samples) |s| sum += @as(f128, @floatFromInt(s));
    const mean = sum / @as(f128, @floatFromInt(iterations));
    var var_acc: f128 = 0;
    for (samples) |s| {
        const d = @as(f128, @floatFromInt(s)) - mean;
        var_acc += d * d;
    }
    const variance = var_acc / @as(f128, @floatFromInt(iterations));
    const cv = std.math.sqrt(variance) / mean;
    var scratch = try alloc.dupe(u64, samples);
    defer alloc.free(scratch);
    const rank = (iterations * 95) / 100;
    var r: usize = 0;
    while (r <= rank) : (r += 1) {
        var min_i = r;
        var j: usize = r + 1;
        while (j < iterations) : (j += 1) {
            if (scratch[j] < scratch[min_i]) min_i = j;
        }
        if (min_i != r) {
            const tmp = scratch[r];
            scratch[r] = scratch[min_i];
            scratch[min_i] = tmp;
        }
    }
    const p95 = @as(f128, @floatFromInt(scratch[rank]));
    const p95_mean = p95 / mean;
    try std.testing.expect(cv <= 0.22);
    try std.testing.expect(p95_mean <= 2.55);
}
