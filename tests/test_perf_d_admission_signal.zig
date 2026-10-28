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
    var ts: std.posix.timespec = undefined;
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
}

fn sleepNs(ns: i64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ns), .awake) catch {};
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
    // Must give up rather than wait indefinitely. This is a liveness bound,
    // not a latency bound: a loaded CI runner can deschedule the waiter well
    // past 50 ms after the futex timeout fires (MR !67, test-zig-unit [4]),
    // so a tight cap flakes. 5 s still catches a waiter that never wakes.
    const liveness_cap_ns: u64 = 5 * std.time.ns_per_s;
    if (elapsed_ns >= timeout_ns + liveness_cap_ns) {
        std.debug.print("acquire({d} ns) returned after {d} ns\n", .{ timeout_ns, elapsed_ns });
    }
    try testing.expect(elapsed_ns < timeout_ns + liveness_cap_ns);

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
            // The timeout is a liveness cap, not a latency bound: the
            // release() below must land while every waiter is still inside
            // acquire(). It was 80 ms, and a loaded CI runner (test-zig-unit
            // [4] on MR !46) descheduled this thread past that, so every
            // waiter timed out before the release and none acquired
            // (`expected 1, found 0`). 2 s still lets the other N-1 waiters
            // re-park and time out, which is what the test checks.
            .timeout_ns = 2 * std.time.ns_per_s,
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
    const release_ns = nowMonoNs();
    throttle.release();

    for (threads) |t| t.join();

    var ok_count: usize = 0;
    var err_count: usize = 0;
    for (&ctxs) |*c| {
        if (c.acquired.load(.acquire)) ok_count += 1;
        if (c.err.load(.acquire) == 1) err_count += 1;
    }
    if (ok_count != 1) {
        for (&ctxs, 0..) |*c, i| {
            // Times relative to the release(): a waiter whose wake is
            // negative timed out before the release reached it.
            std.debug.print("waiter {d}: start={d} ns wake={d} ns acquired={}\n", .{
                i,
                c.start_ns.load(.acquire) - release_ns,
                c.wake_ns.load(.acquire) - release_ns,
                c.acquired.load(.acquire),
            });
        }
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
