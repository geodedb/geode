const std = @import("std");
const perf_gate = @import("perf_gate");

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

fn stats(samples: []const u64) struct { mean: f128, cv: f128, p95_mean: f128 } {
    var sum: f128 = 0;
    for (samples) |s| sum += @as(f128, @floatFromInt(s));
    const mean = sum / @as(f128, @floatFromInt(samples.len));
    var var_acc: f128 = 0;
    for (samples) |s| {
        const diff = @as(f128, @floatFromInt(s)) - mean;
        var_acc += diff * diff;
    }
    const variance = var_acc / @as(f128, @floatFromInt(samples.len));
    const cv = std.math.sqrt(variance) / mean;
    var scratch = std.heap.page_allocator.dupe(u64, samples) catch unreachable;
    defer std.heap.page_allocator.free(scratch);
    const rank = (samples.len * 95) / 100;
    var r: usize = 0;
    while (r <= rank) : (r += 1) {
        var min_index = r;
        var j: usize = r + 1;
        while (j < samples.len) : (j += 1) {
            if (scratch[j] < scratch[min_index]) min_index = j;
        }
        if (min_index != r) {
            const tmp = scratch[r];
            scratch[r] = scratch[min_index];
            scratch[min_index] = tmp;
        }
    }
    const p95 = @as(f128, @floatFromInt(scratch[rank]));
    return .{ .mean = mean, .cv = cv, .p95_mean = p95 / mean };
}

// Placeholder: simulate baseline vs optimized snapshot load by iterating over synthetic records with different stride / cache effects.
// CANARY: REQ=REQ-GQL-022; FEATURE="Storage/Recovery"; ASPECT=SnapshotLoadOptimizationDeltaVariance; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_022_RedoOptimizationDeltaSmoke; BENCH=BenchmarkCANARY_REQ_GQL_022_RedoOptimizationDeltaVarianceEnvelope; OWNER=storage; UPDATED=2026-02-04

fn simulateRedo(records: []u64, optimized: bool) u64 {
    var acc: u64 = 0;
    if (optimized) {
        // assume page-grouped (better locality)
        var i: usize = 0;
        while (i < records.len) : (i += 8) { // grouped application
            var j: usize = i;
            const end = @min(i + 8, records.len);
            while (j < end) : (j += 1) acc +%= records[j] *% 31;
        }
    } else {
        // scatter (simulate random I/O touches)
        var i: usize = 0;
        while (i < records.len) : (i += 1) acc +%= records[i] *% 17;
    }
    return acc;
}

test "TestCANARY_REQ_GQL_022_RedoOptimizationDeltaSmoke" {
    var arr: [512]u64 = undefined;
    for (arr, 0..) |_, i| arr[i] = @as(u64, i) * 13 + 7;
    const base = simulateRedo(&arr, false);
    const opt = simulateRedo(&arr, true);
    // smoke: different accumulation paths likely produce different values
    try std.testing.expect(base != opt);
}

test "BenchmarkCANARY_REQ_GQL_022_RedoOptimizationDeltaVarianceEnvelope" {
    var arr: [2048]u64 = undefined;
    // Wrapping LCG-style fill (SONNY-2394: the plain `*`/`+` overflowed u64
    // and panicked in Debug before a single sample was taken).
    for (arr, 0..) |_, i| arr[i] = (@as(u64, i) *% 6364136223846793005) +% 1;
    const iterations: usize = 64;
    var base_samples: [iterations]u64 = undefined;
    var opt_samples: [iterations]u64 = undefined;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start_b = compat_nanoTimestamp();
        _ = simulateRedo(&arr, false);
        const end_b = compat_nanoTimestamp();
        base_samples[i] = @as(u64, @intCast(end_b - start_b));
        const start_o = compat_nanoTimestamp();
        _ = simulateRedo(&arr, true);
        const end_o = compat_nanoTimestamp();
        opt_samples[i] = @as(u64, @intCast(end_o - start_o));
    }
    const s_base = stats(&base_samples);
    const s_opt = stats(&opt_samples);
    // Perf claims go through the shared gate (SONNY-2394): reported unless
    // GEODE_PERF_GATES=enforce (SONNY-2439) -- see tests/perf_gate.zig.
    // Correctness assertions in this file are not gated.
    // variance envelopes
    try perf_gate.envelope("redo baseline apply", s_base.cv, s_base.p95_mean, 0.22, 2.55);
    try perf_gate.envelope("redo optimized apply", s_opt.cv, s_opt.p95_mean, 0.22, 2.55);
    // optimization should not be slower on mean
    const opt_over_base: f64 = @floatCast(s_opt.mean / s_base.mean);
    try perf_gate.check("optimized redo mean <= 1.05x baseline", opt_over_base <= 1.05, "opt/base={d:.3}", .{opt_over_base});
}
