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

// CANARY: REQ=REQ-GQL-025; FEATURE="Transactions/MVCC"; ASPECT=WriteSkewDetection; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_025_WriteSkewDetection; BENCH=BenchmarkCANARY_REQ_GQL_025_WriteSkewVarianceEnvelope; OWNER=txn; UPDATED=2025-09-21

// Classic write skew: two doctors on-call constraint (must have >=1 doctor on call). Each reads both rows, updates its own to off-call.
// We simulate detection by tracking write-write conflicts to same logical constraint key (constraint:oncall) via shared lock pattern.
test "TestCANARY_REQ_GQL_025_WriteSkewDetection" {
    var mgr: txn.Manager = undefined;
    mgr.init(std.testing.allocator);
    defer mgr.deinit();
    mgr.enablePhantomPrevention(); // reuse phantom infra for predicate registration of constraint key

    var t1 = mgr.begin();
    var t2 = mgr.begin();

    // Represent two doctor rows: doc:1, doc:2  (value=on-call bool) stored via writes
    mgr.recordWrite("doc:1:on", &t1);
    mgr.recordWrite("doc:2:on", &t2);

    // Both capture snapshot (already at begin) and predicate read the constraint namespace
    try mgr.predicateRead(&t1, "doc:");
    try mgr.predicateRead(&t2, "doc:");

    // Each transaction attempts to update its own row to off (introducing potential write skew when both commit)
    mgr.recordWrite("doc:1:off", &t1);
    mgr.recordWrite("doc:2:off", &t2);

    // Commit both; with naive SI write skew would succeed; we emulate detection by observing conflicting predicate + post-start writes
    var t1c = t1; // copy for mutation
    var t2c = t2;
    // Commit t1 first
    _ = mgr.commit(&t1c) catch |e| {
        // Early conflict acceptable, but any other error still propagates
        if (e != error.SerializationFailure and e != error.EarlyConflict) return e;
    };
    // Commit t2 should detect phantom (new write from t1 after t2 start under predicate) or conflict
    const r2 = mgr.commit(&t2c);
    try std.testing.expectError(error.SerializationFailure, r2);
}

// Variance envelope benchmark: measure overhead of write skew detection scenario across iterations.
//
// SONNY-2439: one scenario (a fresh manager, two transactions that both
// predicate-read "doc:" and write, both committed) is one operation; each
// sample is a batch of them, from the production allocator, with robust
// statistics (median, IQR) -- see tests/perf_gate.zig.
const SkewBench = struct {
    fn scenario(_: *SkewBench) !u64 {
        var mgr: txn.Manager = undefined;
        mgr.init(perf_gate.bench_allocator);
        defer mgr.deinit();
        mgr.enablePhantomPrevention();
        var t1 = mgr.begin();
        var t2 = mgr.begin();
        mgr.recordWrite("doc:1:on", &t1);
        mgr.recordWrite("doc:2:on", &t2);
        mgr.predicateRead(&t1, "doc:") catch {};
        mgr.predicateRead(&t2, "doc:") catch {};
        mgr.recordWrite("doc:1:off", &t1);
        mgr.recordWrite("doc:2:off", &t2);
        var aborted: u64 = 0;
        mgr.commit(&t1) catch |e| {
            if (e != error.SerializationFailure and e != error.EarlyConflict) return e;
            aborted += 1;
        };
        mgr.commit(&t2) catch |e| {
            if (e != error.SerializationFailure and e != error.EarlyConflict) return e;
            aborted += 1;
        }; // one abort expected sometimes
        return aborted;
    }
};

test "BenchmarkCANARY_REQ_GQL_025_WriteSkewVarianceEnvelope" {
    var bench: SkewBench = .{};
    var samples: [48]f64 = undefined;
    _ = try perf_gate.timeBatch(&bench, SkewBench.scenario, 32);
    try perf_gate.sampleBatches(&bench, SkewBench.scenario, 32, &samples);
    const r = perf_gate.robust(&samples);
    // Perf claims go through the shared gate (SONNY-2394): reported unless
    // GEODE_PERF_GATES=enforce (SONNY-2439) -- see tests/perf_gate.zig.
    // Correctness assertions in this file are not gated.
    try perf_gate.robustEnvelope("write-skew detection scenario", r, 0.30, 2.55);
}
