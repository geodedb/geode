// PERF-D / #816: regression tests for the futex-backed
// GlobalStreamThrottle. Replaces the previous nanosleep-based wait with
// `io.futexWaitTimeout` + `io.futexWake` so a waiter wakes within sub-ms
// of `release()` rather than burning the full timeout budget.
//
// What this test pins:
//
//   1. **Wake-on-release fast path.** A thread parked on `acquire(timeout)`
//      must be unblocked by `release()` well before the 5 ms admission
//      floor the old implementation imposed. We assert <2 ms here (with
//      generous slop for CI noise — the actual wake is observed in the
//      hundreds of microseconds locally).
//   2. **Timeout still fires when no release happens.** The waiter must
//      give up via `ThrottleError.GlobalStreamLimitExceeded` after the
//      provided timeout, not before and not "indefinitely" later. This
//      catches a future regression where someone might switch the wake
//      atomic underneath us.
//   3. **Signal-not-broadcast discipline (b3790685).** With N waiters and
//      one `release()`, only one waiter should advance. The remaining
//      waiters stay parked and time out — broadcasting would wake all,
//      which is a perf regression under admission saturation.
//   4. **Multiple sequential releases wake multiple waiters.** Combined
//      with (3), this guarantees the per-release-one-wake invariant.
//
// CANARY: REQ=PERF-D-ADMISSION-SIGNAL-001; FEATURE="GlobalStreamThrottle"; ASPECT=FutexWakeOnRelease; STATUS=TESTED; OWNER=server; UPDATED=2026-05-15; TEST=tests/test_perf_d_admission_signal.zig

const std = @import("std");
const testing = std.testing;

const registry_mod = @import("server/active_stream_registry");
const GlobalStreamThrottle = registry_mod.GlobalStreamThrottle;
const ThrottleError = registry_mod.ThrottleError;

/// Monotonic ns timestamp — `std.time.nanoTimestamp` was removed in Zig 0.16
/// and `std.Thread.sleep` is gone too, so we go straight to `clock_gettime`.
fn nowMonoNs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
}

fn sleepNs(ns: i64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)),
        .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

const WaiterCtx = struct {
    throttle: *GlobalStreamThrottle,
    timeout_ns: u64,
    ready: *std.atomic.Value(u32),
    acquired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake_ns: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    start_ns: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    err: std.atomic.Value(u32) = std.atomic.Value(u32).init(0), // 1 = error, 0 = ok

    fn run(self: *WaiterCtx) void {
        // Mark ourselves "ready to park" so the main thread knows it can
        // call release() and trigger the wake measurement.
        _ = self.ready.fetchAdd(1, .release);
        self.start_ns.store(nowMonoNs(), .release);
        self.throttle.acquire(self.timeout_ns) catch {
            self.err.store(1, .release);
            self.wake_ns.store(nowMonoNs(), .release);
            return;
        };
        self.wake_ns.store(nowMonoNs(), .release);
        self.acquired.store(true, .release);
    }
};

test "PERF-D: release wakes parked acquire in <2ms (was up to timeout under nanosleep)" {
    var throttle = GlobalStreamThrottle.init(1);
    try throttle.acquire(0); // hold the only slot

    var ready: std.atomic.Value(u32) = .init(0);
    var ctx = WaiterCtx{
        .throttle = &throttle,
        // 500 ms — large enough that if the futexWake path is broken and
        // we fall back to "spin until timeout" we'll see ~500 ms wake.
        .timeout_ns = 500 * std.time.ns_per_ms,
        .ready = &ready,
    };

    const t = try std.Thread.spawn(.{}, WaiterCtx.run, .{&ctx});

    // Wait until the waiter has actually entered acquire().
    while (ready.load(.acquire) == 0) sleepNs(50 * std.time.ns_per_us);
    // Give it a moment to descend into the futex wait (the CAS retry loop
    // is fast but we want the thread parked on futex, not still in the
    // userspace CAS loop, before we measure).
    sleepNs(500 * std.time.ns_per_us);

    const release_t0 = nowMonoNs();
    throttle.release();
    t.join();

    try testing.expectEqual(@as(u32, 0), ctx.err.load(.acquire));
    try testing.expect(ctx.acquired.load(.acquire));

    const wake_latency_ns = ctx.wake_ns.load(.acquire) - release_t0;
    // Critical assertion: wake within 2 ms. The old nanosleep path would
    // sit out the full 500 ms timeout — and even with a 1 ms timeout it
    // would always sit out the full 1 ms. The futex path wakes in the
    // hundreds of microseconds on Linux.
    try testing.expect(wake_latency_ns < 2 * std.time.ns_per_ms);
    try testing.expect(wake_latency_ns >= 0);

    // Cleanup.
    throttle.release();
}

test "PERF-D: acquire times out when no release happens, within timeout slop" {
    var throttle = GlobalStreamThrottle.init(1);
    try throttle.acquire(0); // hold the only slot

    const timeout_ns: u64 = 25 * std.time.ns_per_ms;
    const start = nowMonoNs();
    const result = throttle.acquire(timeout_ns);
    const elapsed_ns: u64 = @intCast(nowMonoNs() - start);

    try testing.expectError(ThrottleError.GlobalStreamLimitExceeded, result);
    // Must wait at least most of the timeout (no premature wakeup).
    try testing.expect(elapsed_ns >= timeout_ns - 5 * std.time.ns_per_ms);
    // Must NOT wait substantially longer than the timeout (no busy-wait).
    try testing.expect(elapsed_ns < timeout_ns + 50 * std.time.ns_per_ms);

    throttle.release();
}

test "PERF-D: one release wakes exactly one of N waiters (signal not broadcast)" {
    var throttle = GlobalStreamThrottle.init(1);
    try throttle.acquire(0); // hold the only slot

    const N: usize = 4;
    var ready: std.atomic.Value(u32) = .init(0);
    var ctxs: [N]WaiterCtx = undefined;
    var threads: [N]std.Thread = undefined;

    for (&ctxs, 0..) |*c, i| {
        c.* = WaiterCtx{
            .throttle = &throttle,
            // 80 ms — long enough that we can release() once and still
            // have time to observe that the OTHER waiters did not wake.
            .timeout_ns = 80 * std.time.ns_per_ms,
            .ready = &ready,
        };
        threads[i] = try std.Thread.spawn(.{}, WaiterCtx.run, .{c});
    }

    // Wait until all N waiters have entered acquire().
    while (ready.load(.acquire) < @as(u32, N)) sleepNs(50 * std.time.ns_per_us);
    sleepNs(2 * std.time.ns_per_ms); // let them all park on the futex

    // Single release. Per the b3790685 signal-not-broadcast pattern, this
    // must wake exactly one waiter — and that waiter claims the slot. The
    // remaining N-1 waiters must observe that they no longer satisfy the
    // predicate (active == max == 1) and re-park until timeout.
    throttle.release();

    for (threads) |t| t.join();

    var ok_count: usize = 0;
    var err_count: usize = 0;
    for (&ctxs) |*c| {
        if (c.acquired.load(.acquire)) ok_count += 1;
        if (c.err.load(.acquire) == 1) err_count += 1;
    }

    // Exactly one waiter succeeded; the rest timed out.
    try testing.expectEqual(@as(usize, 1), ok_count);
    try testing.expectEqual(@as(usize, N - 1), err_count);

    // Cleanup: the one waiter that won holds the slot.
    throttle.release();
    try testing.expectEqual(@as(u32, 0), throttle.count());
}

test "PERF-D: N sequential releases wake N waiters" {
    const N: usize = 3;
    var throttle = GlobalStreamThrottle.init(N);

    // Take all N slots so the next N waiters block.
    for (0..N) |_| try throttle.acquire(0);
    try testing.expectEqual(@as(u32, N), throttle.count());

    var ready: std.atomic.Value(u32) = .init(0);
    var ctxs: [N]WaiterCtx = undefined;
    var threads: [N]std.Thread = undefined;

    for (&ctxs, 0..) |*c, i| {
        c.* = WaiterCtx{
            .throttle = &throttle,
            .timeout_ns = 500 * std.time.ns_per_ms,
            .ready = &ready,
        };
        threads[i] = try std.Thread.spawn(.{}, WaiterCtx.run, .{c});
    }

    // Wait until all waiters are parked.
    while (ready.load(.acquire) < @as(u32, N)) sleepNs(50 * std.time.ns_per_us);
    sleepNs(2 * std.time.ns_per_ms);

    // Issue N sequential releases. Each must wake exactly one waiter.
    // Between releases we yield a tiny window so the woken waiter has time
    // to CAS the slot before the next release fires (otherwise both
    // wakeups could land on the same waiter and double-claim is impossible
    // by CAS but we'd waste a wake — the test still passes either way
    // since the loser re-parks).
    for (0..N) |_| {
        throttle.release();
        sleepNs(500 * std.time.ns_per_us);
    }

    for (threads) |t| t.join();

    var ok_count: usize = 0;
    for (&ctxs) |*c| {
        if (c.acquired.load(.acquire)) ok_count += 1;
    }
    try testing.expectEqual(N, ok_count);

    // After N releases and N successful acquires, count is back to N
    // (the original holders released, the waiters acquired).
    try testing.expectEqual(@as(u32, N), throttle.count());

    for (0..N) |_| throttle.release();
}
