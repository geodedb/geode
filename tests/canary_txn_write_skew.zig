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
test "BenchmarkCANARY_REQ_GQL_025_WriteSkewVarianceEnvelope" {
    const iterations: usize = 48;
    var samples: [iterations]u64 = undefined;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var mgr: txn.Manager = undefined;
        mgr.init(std.testing.allocator);
        mgr.enablePhantomPrevention();
        var t1 = mgr.begin();
        var t2 = mgr.begin();
        mgr.recordWrite("doc:1:on", &t1);
        mgr.recordWrite("doc:2:on", &t2);
        mgr.predicateRead(&t1, "doc:") catch {};
        mgr.predicateRead(&t2, "doc:") catch {};
        mgr.recordWrite("doc:1:off", &t1);
        mgr.recordWrite("doc:2:off", &t2);
        var t1c = t1;
        var t2c = t2;
        const start = compat_nanoTimestamp();
        _ = mgr.commit(&t1c) catch |e| {
            if (e != error.SerializationFailure and e != error.EarlyConflict) return e;
        };
        _ = mgr.commit(&t2c) catch |e| {
            if (e != error.SerializationFailure and e != error.EarlyConflict) return e;
        }; // one abort expected sometimes
        const end = compat_nanoTimestamp();
        samples[i] = @as(u64, @intCast(end - start));
        mgr.deinit();
    }
    var sum: f128 = 0;
    for (samples) |s| sum += @as(f128, @floatFromInt(s));
    const mean = sum / @as(f128, @floatFromInt(iterations));
    var var_acc: f128 = 0;
    for (samples) |s| {
        const diff = @as(f128, @floatFromInt(s)) - mean;
        var_acc += diff * diff;
    }
    const variance = var_acc / @as(f128, @floatFromInt(iterations));
    const cv = std.math.sqrt(variance) / mean;
    // simple selection for p95
    var scratch = samples; // copy array
    const rank = (iterations * 95) / 100;
    var r: usize = 0;
    while (r <= rank) : (r += 1) {
        var min_index = r;
        var j: usize = r + 1;
        while (j < iterations) : (j += 1) {
            if (scratch[j] < scratch[min_index]) min_index = j;
        }
        if (min_index != r) {
            const tmp = scratch[r];
            scratch[r] = scratch[min_index];
            scratch[min_index] = tmp;
        }
    }
    const p95 = @as(f128, @floatFromInt(scratch[rank]));
    const p95_mean = p95 / mean;
    // Perf claims go through the shared gate (SONNY-2394): reported unless
    // GEODE_PERF_GATES=enforce (SONNY-2439) -- see tests/perf_gate.zig.
    // Correctness assertions in this file are not gated.
    try perf_gate.envelope("write-skew detection commit", cv, p95_mean, 0.22, 2.55);
}
