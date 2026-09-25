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

const txn = @import("txn");

// CANARY: REQ=REQ-GQL-023; FEATURE="MVCC Phantom Prevention"; ASPECT=RangeTracker; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_023_PhantomPreventionRangeDetection; OWNER=txn; UPDATED=2025-09-22

fn mean(samples: []const f64) f64 {
    var acc: f64 = 0;
    for (samples) |v| acc += v;
    return acc / @as(f64, @floatFromInt(samples.len));
}

fn stddev(samples: []const f64, m: f64) f64 {
    var acc: f64 = 0;
    for (samples) |v| acc += (v - m) * (v - m);
    return @sqrt(acc / @as(f64, @floatFromInt(samples.len)));
}

test "TestCANARY_REQ_GQL_023_PhantomPreventionRangeDetection" {
    var mgr: txn.Manager = undefined;
    mgr.init(std.testing.allocator);
    defer mgr.deinit();
    mgr.enablePhantomPrevention();

    var t1 = mgr.begin();
    var t2 = mgr.begin();

    // T1 reads a range ["cust:100", "cust:200"]
    try mgr.rangeRead(&t1, "cust:100", "cust:200");
    // T2 inserts a key inside that range after T1 snapshot
    mgr.recordWrite("cust:150", &t2);
    try mgr.commit(&t2); // commit write inside range after T1 start

    // T1 attempts to commit -> should detect phantom and fail
    try std.testing.expectError(error.SerializationFailure, mgr.commit(&t1));
}

// CANARY: REQ=REQ-GQL-023; FEATURE="MVCC Phantom Prevention"; ASPECT=RangeTracker; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_023_PhantomPreventionOverheadVarianceEnvelope; OWNER=txn; UPDATED=2025-09-22
test "BenchmarkCANARY_REQ_GQL_023_PhantomPreventionOverheadVarianceEnvelope" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mgr_base: txn.Manager = undefined;
    mgr_base.init(allocator);
    defer mgr_base.deinit();

    var mgr_range: txn.Manager = undefined;
    mgr_range.init(allocator);
    mgr_range.enablePhantomPrevention();
    defer mgr_range.deinit();

    const iters: usize = 300; // enough for variance stability but fast
    var base_samples = try allocator.alloc(f64, iters);
    defer allocator.free(base_samples);
    var range_samples = try allocator.alloc(f64, iters);
    defer allocator.free(range_samples);

    var i: usize = 0;
    while (i < iters) : (i += 1) {
        var t = mgr_base.begin();
        const start = compat_microTimestamp();
        // simulate a few predicate prefix reads only (baseline already uses prefix list mechanics)
        try mgr_base.predicateRead(&t, "cust:");
        try mgr_base.predicateRead(&t, "order:");
        _ = mgr_base.commit(&t) catch {}; // ignore serialization outcomes here
        const end = compat_microTimestamp();
        base_samples[i] = @as(f64, @floatFromInt(end - start));
    }

    i = 0;
    while (i < iters) : (i += 1) {
        var t = mgr_range.begin();
        const start = compat_microTimestamp();
        try mgr_range.predicateRead(&t, "cust:");
        try mgr_range.rangeRead(&t, "cust:100", "cust:300");
        try mgr_range.rangeRead(&t, "order:050", "order:999");
        _ = mgr_range.commit(&t) catch {};
        const end = compat_microTimestamp();
        range_samples[i] = @as(f64, @floatFromInt(end - start));
    }

    const m_base = mean(base_samples);
    const m_range = mean(range_samples);
    _ = stddev(base_samples, m_base); // discard base stddev (not needed for thresholds)
    const sd_range = stddev(range_samples, m_range);
    // base CV currently unused but retained for potential comparative reporting (omit to avoid unused warning)
    const cv_range = if (m_range == 0) 0 else sd_range / m_range;
    const p95_idx = (iters * 95) / 100 - 1;
    std.sort.block(f64, base_samples, {}, comptime std.sort.asc(f64));
    std.sort.block(f64, range_samples, {}, comptime std.sort.asc(f64));
    const p95_range = range_samples[p95_idx];
    const ratio_p95_mean_range = if (m_range == 0) 0 else p95_range / m_range;

    // Envelope thresholds (general CV <=0.22, p95/mean <=2.55) + overhead guard <5%
    // Perf claims go through the shared gate (SONNY-2394): reported unless
    // GEODE_PERF_GATES=enforce (SONNY-2439) -- see tests/perf_gate.zig.
    // Correctness assertions in this file are not gated.
    const overhead = if (m_base == 0) 0 else (m_range - m_base) / m_base;
    std.debug.print("CANARY_RANGE_OVERHEAD mean_base={d:.2} mean_range={d:.2} overhead={d:.4} cv_range={d:.4} p95/mean={d:.2}\n", .{ m_base, m_range, overhead, cv_range, ratio_p95_mean_range });
    try perf_gate.envelope("range-tracked commit latency", cv_range, ratio_p95_mean_range, 0.22, 2.55);
    try perf_gate.check("range tracking overhead <= 5%", overhead <= 0.05, "overhead={d:.4}", .{overhead});
}
