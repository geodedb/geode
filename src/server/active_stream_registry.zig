const std = @import("std");

// CANARY: REQ=REQ-QUIC-MUX-004; FEATURE="ActiveStreamRegistry"; ASPECT=ConnectionStreamOwnership; STATUS=IMPL; OWNER=server; UPDATED=2026-04-08
// The first stream is accepted before the acceptor loop starts. Additional
// peer-initiated streams are capped separately to prevent resource exhaustion.
pub const max_additional_streams_per_connection: u32 = 64;
pub const max_total_streams_per_connection: u32 = max_additional_streams_per_connection + 1;

// CANARY: REQ=PERF-P1-004; FEATURE="GlobalStreamThrottle"; ASPECT=ThreadExhaustionPrevention; STATUS=TESTED; OWNER=server; UPDATED=2026-04-10
/// Default maximum number of concurrent stream handler threads across ALL
/// connections. With the per-connection cap of 65 streams, 100 connections
/// could spawn up to 6,500 OS threads. This global cap prevents thread
/// exhaustion while still allowing substantial concurrency.
pub const default_max_global_stream_threads: u32 = 256;

pub const ThrottleError = error{
    /// The global stream thread limit has been reached and the wait
    /// timed out without a slot becoming available.
    GlobalStreamLimitExceeded,
};

pub const RegistryError = error{
    StreamRegistryFull,
};

// CANARY: REQ=PERF-P1-004; FEATURE="GlobalStreamThrottle"; ASPECT=GlobalAtomicCounter; STATUS=TESTED; OWNER=server; UPDATED=2026-05-15
/// Global throttle that caps the total number of concurrent stream handler
/// threads across all QUIC connections. Uses an atomic counter for the fast
/// path and a futex (`futexWaitTimeout`/`futexWake` on the same atomic) for
/// backpressure when the limit is reached.
///
/// PERF-D / #816: prior to 2026-05-15 the slow path used `nanosleep(timeout)`
/// because `std.Io.Condition.waitTimeout` does not exist in Zig 0.16. That
/// imposed a fixed wake-up latency floor (the full timeout) even when a slot
/// freed immediately. We now park the waiter on the `active` counter via
/// `io.futexWaitTimeout` and have `release()` call `io.futexWake` after
/// `fetchSub`, so a waiter wakes within the futex wake latency (sub-ms in
/// the synthetic test, see tests/test_perf_d_admission_signal.zig). Follows
/// the b3790685 signal-vs-broadcast discipline: `futexWake(..., 1)` rather
/// than wake-all, since admission has at most one slot freed per release.
pub const GlobalStreamThrottle = struct {
    /// Current number of active stream handler threads. Used both as the
    /// admission counter (CAS) and as the futex wait address (so a waiter
    /// can park on a specific observed value).
    active: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Maximum allowed concurrent stream handler threads.
    max: u32,

    pub fn init(max: u32) GlobalStreamThrottle {
        return .{ .max = max };
    }

    /// Try to acquire a slot for a new stream handler thread.
    /// If below the limit, increments the counter and returns immediately.
    /// If at the limit, waits up to `timeout_ns` for a slot to open.
    /// Returns `ThrottleError.GlobalStreamLimitExceeded` if the wait times out.
    pub fn acquire(self: *GlobalStreamThrottle, timeout_ns: u64) ThrottleError!void {
        const io = std.Io.Threaded.global_single_threaded.io();

        // Fast path: atomically try to increment if below the limit. If a
        // slot is available, claim it via CAS and return.
        if (self.tryClaimSlot()) return;

        // Slow path: at the limit. If the caller gave a zero timeout, fail
        // immediately (preserves existing semantics for non-blocking
        // acquire(0) used in the unit tests).
        if (timeout_ns == 0) return ThrottleError.GlobalStreamLimitExceeded;

        // Park on the atomic counter with a deadline. Each loop iteration:
        //   1) Snapshot the current count.
        //   2) If a slot is now free, try to claim it.
        //   3) Otherwise futexWaitTimeout(..., snapshot, remaining).
        //      Returns when:
        //        * release() called futexWake (signal path), or
        //        * the value already differs from `snapshot` (race), or
        //        * the timeout fires, or
        //        * a spurious wakeup occurs.
        //      Per the canonical futex idiom we re-check on every return.
        const start_ns = nowMonotonicNs();
        var remaining_ns: u64 = timeout_ns;
        while (true) {
            const current = self.active.load(.acquire);
            if (current < self.max) {
                if (self.tryClaimSlot()) return;
                // CAS lost race; reload and retry.
                continue;
            }

            const timeout: std.Io.Timeout = .{ .duration = .{
                .raw = std.Io.Duration.fromNanoseconds(@intCast(remaining_ns)),
                .clock = .awake,
            } };
            io.futexWaitTimeout(u32, &self.active.raw, current, timeout) catch |err| switch (err) {
                // We don't introduce cancelation points here (the QUIC
                // accept loop already treats acquire as a budgeted wait).
                error.Canceled => return ThrottleError.GlobalStreamLimitExceeded,
            };

            // Update remaining budget. If the deadline has passed, do one
            // final check (in case the wake won the race with the timeout)
            // and then give up.
            const elapsed_ns: u64 = @intCast(nowMonotonicNs() - start_ns);
            if (elapsed_ns >= timeout_ns) {
                if (self.tryClaimSlot()) return;
                return ThrottleError.GlobalStreamLimitExceeded;
            }
            remaining_ns = timeout_ns - elapsed_ns;
        }
    }

    /// Release a slot when a stream handler thread exits.
    /// Must be called exactly once for each successful `acquire`.
    pub fn release(self: *GlobalStreamThrottle) void {
        const prev = self.active.fetchSub(1, .release);
        std.debug.assert(prev > 0); // underflow guard

        // PERF-D / #816: wake exactly one waiter (per b3790685 — only one
        // slot freed, so only one waiter needs to advance). The store side
        // of fetchSub is .release; futexWake performs an acquire-side
        // synchronization on the kernel queue, so the waker's update is
        // visible to the woken thread before its re-check of `active`.
        const io = std.Io.Threaded.global_single_threaded.io();
        io.futexWake(u32, &self.active.raw, 1);
    }

    /// Return the current number of active stream handler threads.
    pub fn count(self: *const GlobalStreamThrottle) u32 {
        return self.active.load(.acquire);
    }

    /// Try to atomically claim one slot. Returns true on success.
    fn tryClaimSlot(self: *GlobalStreamThrottle) bool {
        while (true) {
            const current = self.active.load(.acquire);
            if (current >= self.max) return false;
            if (self.active.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |_| {
                // Lost the CAS (contention); retry.
                continue;
            }
            return true;
        }
    }
};

/// Monotonic timestamp in nanoseconds. Used by the throttle wait loop to
/// compute the remaining timeout across spurious wakeups.
fn nowMonotonicNs() i128 {
    if (comptime @import("builtin").os.tag == .linux) {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
    } else {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return @as(i128, ts.tv_sec) * std.time.ns_per_s + @as(i128, ts.tv_nsec);
    }
}

pub const ActiveStreamRegistry = struct {
    mu: std.Io.Mutex = std.Io.Mutex.init,
    len: usize = 0,
    ids: [max_total_streams_per_connection]u64 = [_]u64{0} ** max_total_streams_per_connection,

    pub fn register(self: *ActiveStreamRegistry, stream_id: u64) RegistryError!bool {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.containsLocked(stream_id)) return false;
        if (self.len == self.ids.len) return error.StreamRegistryFull;

        self.ids[self.len] = stream_id;
        self.len += 1;
        return true;
    }

    pub fn unregister(self: *ActiveStreamRegistry, stream_id: u64) bool {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.unregisterLocked(stream_id);
    }

    pub fn contains(self: *ActiveStreamRegistry, stream_id: u64) bool {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.containsLocked(stream_id);
    }

    pub fn count(self: *ActiveStreamRegistry) usize {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.len;
    }

    fn containsLocked(self: *const ActiveStreamRegistry, stream_id: u64) bool {
        for (self.ids[0..self.len]) |active_stream_id| {
            if (active_stream_id == stream_id) return true;
        }
        return false;
    }

    fn unregisterLocked(self: *ActiveStreamRegistry, stream_id: u64) bool {
        for (self.ids[0..self.len], 0..) |active_stream_id, index| {
            if (active_stream_id == stream_id) {
                self.len -= 1;
                self.ids[index] = self.ids[self.len];
                self.ids[self.len] = 0;
                return true;
            }
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ActiveStreamRegistry register and unregister" {
    var reg = ActiveStreamRegistry{};
    try std.testing.expect(try reg.register(1));
    try std.testing.expect(try reg.register(2));
    try std.testing.expectEqual(@as(usize, 2), reg.count());

    // Duplicate returns false (already registered).
    try std.testing.expect(!try reg.register(1));
    try std.testing.expectEqual(@as(usize, 2), reg.count());

    // Unregister works.
    try std.testing.expect(reg.unregister(1));
    try std.testing.expectEqual(@as(usize, 1), reg.count());

    // Second unregister of same id returns false.
    try std.testing.expect(!reg.unregister(1));
}

test "ActiveStreamRegistry rejects when full" {
    var reg = ActiveStreamRegistry{};
    for (0..max_total_streams_per_connection) |i| {
        try std.testing.expect(try reg.register(@intCast(i + 100)));
    }
    try std.testing.expectError(error.StreamRegistryFull, reg.register(9999));
}

test "GlobalStreamThrottle acquire and release" {
    var throttle = GlobalStreamThrottle.init(3);
    try std.testing.expectEqual(@as(u32, 0), throttle.count());

    // Acquire 3 slots (at the limit).
    try throttle.acquire(0);
    try throttle.acquire(0);
    try throttle.acquire(0);
    try std.testing.expectEqual(@as(u32, 3), throttle.count());

    // Fourth acquire with zero timeout must fail.
    try std.testing.expectError(ThrottleError.GlobalStreamLimitExceeded, throttle.acquire(0));
    try std.testing.expectEqual(@as(u32, 3), throttle.count());

    // Release one and try again.
    throttle.release();
    try std.testing.expectEqual(@as(u32, 2), throttle.count());

    try throttle.acquire(0);
    try std.testing.expectEqual(@as(u32, 3), throttle.count());

    // Cleanup.
    throttle.release();
    throttle.release();
    throttle.release();
    try std.testing.expectEqual(@as(u32, 0), throttle.count());
}

test "GlobalStreamThrottle acquire times out under contention" {
    var throttle = GlobalStreamThrottle.init(1);
    try throttle.acquire(0);

    // With the single slot taken, a short timeout should fail.
    try std.testing.expectError(
        ThrottleError.GlobalStreamLimitExceeded,
        throttle.acquire(1 * std.time.ns_per_ms),
    );

    throttle.release();
}

test "GlobalStreamThrottle release wakes waiter" {
    var throttle = GlobalStreamThrottle.init(1);
    try throttle.acquire(0); // take the only slot

    var acquired = std.atomic.Value(bool).init(false);

    // Spawn a thread that waits for a slot.
    const t = try std.Thread.spawn(.{}, struct {
        fn run(th: *GlobalStreamThrottle, flag: *std.atomic.Value(bool)) void {
            th.acquire(500 * std.time.ns_per_ms) catch return;
            flag.store(true, .release);
        }
    }.run, .{ &throttle, &acquired });

    // Give the waiter time to enter the condvar wait.
    std.Thread.sleep(5 * std.time.ns_per_ms);

    // Release our slot — this should wake the waiter.
    throttle.release();

    t.join();
    try std.testing.expect(acquired.load(.acquire));

    // The waiter acquired the slot, so count should be 1.
    try std.testing.expectEqual(@as(u32, 1), throttle.count());
    throttle.release();
}
