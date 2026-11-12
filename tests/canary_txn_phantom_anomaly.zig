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

const txn_mod = @import("txn");

// CANARY: REQ=REQ-GQL-023; FEATURE="MVCC Phantom Prevention"; ASPECT=PredicateRangeDetection; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_023_PhantomDetection; BENCH=BenchmarkCANARY_REQ_GQL_023_PhantomOverheadVarianceEnvelope; OWNER=txn; UPDATED=2025-09-21

// This test validates predicate range read phantom detection using prefix-based predicates.
// Scenario:
//  T1 begins, enables phantom prevention, performs predicate read on prefix "acct:" capturing baseline keys.
//  T2 begins after T1, inserts a new key with prefix "acct:" and commits.
//  T1 attempts to commit; phantom detection should see T2's committed write with commit_ts > T1.start_ts
//  and overlapping predicate, causing SerializationFailure.
// Implementation detail: predicateRead records prefix; writes tracked with commit_ts.

test "TestCANARY_REQ_GQL_023_PhantomDetection" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mgr: txn_mod.Manager = undefined;
    mgr.init(allocator);
    defer mgr.deinit();
    mgr.enablePhantomPrevention();

    var t1 = mgr.begin();
    try mgr.predicateRead(&t1, "acct:");

    var t2 = mgr.begin();
    // Simulate insert under t2
    mgr.recordWrite("acct:3", &t2);
    try mgr.commit(&t2);

    // Commit t1 should now fail with SerializationFailure due to phantom
    const res = mgr.commit(&t1);
    try std.testing.expectError(error.SerializationFailure, res);
    try std.testing.expectEqual(@as(txn_mod.TxnState, .Aborted), t1.state);
}

// Benchmark capturing overhead of phantom prevention tracking vs disabled mode.
// Helper stats function (top-level so Zig allows declaration outside test scope)
const Stats = struct { mean: f64, p95: f64, cv: f64 };
fn stats(data: []const u64) Stats {
    var sum: f128 = 0;
    for (data) |v| sum += @as(f128, @floatFromInt(v));
    const flen = @as(f128, @floatFromInt(data.len));
    const mean = @as(f64, @floatCast(sum / flen));
    var var_acc: f128 = 0;
    for (data) |v| {
        const dv = @as(f128, @floatFromInt(v)) - @as(f128, mean);
        var_acc += dv * dv;
    }
    const variance = var_acc / flen;
    const stddev = std.math.sqrt(@as(f64, @floatCast(variance)));
    const cv = if (mean == 0) 0 else stddev / mean;
    // Approximate p95 using naive selection (copy into fixed buffer)
    var buf: [512]u64 = undefined;
    const n = data.len;
    var i: usize = 0;
    while (i < n) : (i += 1) buf[i] = data[i];
    const target = (n * 95) / 100;
    // simple partial selection O(n^2) worst-case but fine for n<=200
    var a: usize = 0;
    while (a <= target) : (a += 1) {
        var min_idx = a;
        var b: usize = a + 1;
        while (b < n) : (b += 1) {
            if (buf[b] < buf[min_idx]) min_idx = b;
        }
        if (min_idx != a) {
            const tmpv = buf[a];
            buf[a] = buf[min_idx];
            buf[min_idx] = tmpv;
        }
    }
    const p95 = @as(f64, @floatFromInt(buf[target]));
    return .{ .mean = mean, .p95 = p95, .cv = cv };
}

test "BenchmarkCANARY_REQ_GQL_023_PhantomOverheadVarianceEnvelope" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const iters: usize = 200; // keep lightweight
    var samples_disabled = try allocator.alloc(u64, iters);
    defer allocator.free(samples_disabled);
    var samples_enabled = try allocator.alloc(u64, iters);
    defer allocator.free(samples_enabled);

    // Helper to run a micro workload
    inline for (.{ false, true }) |enabled| {
        const s_ptr = if (enabled) &samples_enabled else &samples_disabled;
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            var mgr: txn_mod.Manager = undefined;
            mgr.init(allocator);
            defer mgr.deinit();
            if (enabled) mgr.enablePhantomPrevention();
            var t = mgr.begin();
            // 5 predicate reads
            var j: usize = 0;
            while (j < 5) : (j += 1) {
                if (enabled) mgr.predicateRead(&t, "acct:") catch {};
            }
            // 10 writes
            var k: usize = 0;
            while (k < 10) : (k += 1) {
                var buf: [16]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "acct:{d}", .{k}) catch "acct:err";
                mgr.recordWrite(key, &t);
            }
            const start = compat_microTimestamp();
            _ = mgr.commit(&t) catch {}; // ignore serialization failures
            const end = compat_microTimestamp();
            const dur: u64 = @intCast(end - start);
            s_ptr.*[i] = dur;
        }
    }

    // Compute stats
    const st_disabled = stats(samples_disabled);
    const st_enabled = stats(samples_enabled);
    // Perf claims go through the shared gate (SONNY-2394): reported unless
    // GEODE_PERF_GATES=enforce (SONNY-2439) -- see tests/perf_gate.zig.
    // Correctness assertions in this file are not gated.
    // Overhead <=5%
    if (st_disabled.mean > 0) {
        const overhead = (st_enabled.mean - st_disabled.mean) / st_disabled.mean;
        try perf_gate.check("phantom prevention commit overhead <= 5%", overhead <= 0.05, "overhead={d:.4}", .{overhead});
    }
    // Variance thresholds
    const p95_mean = if (st_enabled.mean > 0) st_enabled.p95 / st_enabled.mean else 0;
    try perf_gate.envelope("phantom prevention commit latency", st_enabled.cv, p95_mean, 0.22, 2.55);
}
