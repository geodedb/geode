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

const txn = @import("txn");

// CANARY: REQ=REQ-GQL-023; FEATURE="MVCC Phantom Prevention"; ASPECT=RangeTracker; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_023_PhantomPreventionRangeDetection; OWNER=txn; UPDATED=2025-09-22

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

// CANARY: REQ=REQ-GQL-023; FEATURE="MVCC Phantom Prevention"; ASPECT=RangeTracker; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_023_PhantomPreventionOverheadVarianceEnvelope; OWNER=txn; UPDATED=2026-11-12
//
// SONNY-2439: the baseline manager never enabled phantom prevention, so its
// predicateRead calls returned at once (manager.zig predicateRead) and the
// "overhead" divided a full commit by an almost empty one, timed per
// transaction on a microsecond clock. Both arms now run with phantom
// prevention on and differ only in the two range reads; each sample is a
// batch of whole transactions (begin .. commit), the arms are interleaved,
// the claims use the median and IQR (tests/perf_gate.zig), and the
// transactions allocate from the production allocator.
const RangeBench = struct {
    base: *txn.Manager,
    range: *txn.Manager,

    fn baseTxn(self: *RangeBench) !u64 {
        var t = self.base.begin();
        try self.base.predicateRead(&t, "cust:");
        try self.base.predicateRead(&t, "order:");
        _ = self.base.commit(&t) catch {}; // serialization outcomes are not timed separately
        return t.id;
    }

    fn rangeTxn(self: *RangeBench) !u64 {
        var t = self.range.begin();
        try self.range.predicateRead(&t, "cust:");
        try self.range.rangeRead(&t, "cust:100", "cust:300");
        try self.range.rangeRead(&t, "order:050", "order:999");
        _ = self.range.commit(&t) catch {};
        return t.id;
    }
};

test "BenchmarkCANARY_REQ_GQL_023_PhantomPreventionOverheadVarianceEnvelope" {
    const allocator = perf_gate.bench_allocator;

    var mgr_base: txn.Manager = undefined;
    mgr_base.init(allocator);
    mgr_base.enablePhantomPrevention();
    defer mgr_base.deinit();

    var mgr_range: txn.Manager = undefined;
    mgr_range.init(allocator);
    mgr_range.enablePhantomPrevention();
    defer mgr_range.deinit();

    var bench: RangeBench = .{ .base = &mgr_base, .range = &mgr_range };
    const samples: usize = 64;
    const batch: usize = 64;
    var base_samples: [samples]f64 = undefined;
    var range_samples: [samples]f64 = undefined;
    // Warm-up, then the measured interleaved rounds.
    _ = try perf_gate.timeBatch(&bench, RangeBench.baseTxn, batch);
    _ = try perf_gate.timeBatch(&bench, RangeBench.rangeTxn, batch);
    try perf_gate.interleavedAB(&bench, RangeBench.baseTxn, RangeBench.rangeTxn, batch, &base_samples, &range_samples);

    const rb = perf_gate.robust(&base_samples);
    const rr = perf_gate.robust(&range_samples);
    const overhead = perf_gate.medianOverhead(rb, rr);
    std.debug.print("CANARY_RANGE_OVERHEAD median_base={d:.1}ns median_range={d:.1}ns overhead={d:.4} rel_iqr_range={d:.4} p95/median={d:.2}\n", .{ rb.median, rr.median, overhead, rr.rel_iqr, rr.p95_over_median });
    // Perf claims go through the shared gate (SONNY-2394): reported unless
    // GEODE_PERF_GATES=enforce (SONNY-2439) -- see tests/perf_gate.zig.
    // Correctness assertions in this file are not gated.
    try perf_gate.robustEnvelope("range-tracked transaction latency", rr, 0.30, 2.55);
    try perf_gate.check("range tracking overhead <= 5%", overhead <= 0.05, "overhead={d:.4}", .{overhead});
}
