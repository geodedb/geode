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

// CANARY: REQ=PERF-P1-004; FEATURE="GlobalStreamThrottle"; ASPECT=GlobalAtomicCounter; STATUS=TESTED; OWNER=server; UPDATED=2026-04-10
/// Global throttle that caps the total number of concurrent stream handler
/// threads across all QUIC connections. Uses an atomic counter for the fast
/// path and a mutex + condvar for backpressure when the limit is reached.
pub const GlobalStreamThrottle = struct {
    /// Current number of active stream handler threads.
    active: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Maximum allowed concurrent stream handler threads.
    max: u32,
    /// Mutex protecting the condvar wait.
    mu: std.Thread.Mutex = .{},
    /// Condition variable signalled when a stream handler thread exits.
    cv: std.Thread.Condition = .{},

    pub fn init(max: u32) GlobalStreamThrottle {
        return .{ .max = max };
    }

    /// Try to acquire a slot for a new stream handler thread.
    /// If below the limit, increments the counter and returns true immediately.
    /// If at the limit, waits up to `timeout_ns` for a slot to open.
    /// Returns `ThrottleError.GlobalStreamLimitExceeded` if the wait times out.
    pub fn acquire(self: *GlobalStreamThrottle, timeout_ns: u64) ThrottleError!void {
        // Fast path: atomically try to increment if below the limit.
        while (true) {
            const current = self.active.load(.acquire);
            if (current < self.max) {
                // Try to claim a slot via CAS.
                if (self.active.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |_| {
                    // CAS failed (contention), retry the loop.
                    continue;
                }
                // Successfully claimed a slot.
                return;
            }
            break;
        }

        // Slow path: at the limit, wait with backpressure.
        self.mu.lock();
        defer self.mu.unlock();

        // Re-check under the lock in case a slot opened between the fast
        // path failure and acquiring the mutex.
        while (true) {
            const current = self.active.load(.acquire);
            if (current < self.max) {
                if (self.active.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |_| {
                    continue;
                }
                return;
            }
            break;
        }

        // Wait for a signal with timeout.
        self.cv.timedWait(&self.mu, timeout_ns) catch {
            // Timeout expired. One final check before giving up.
            while (true) {
                const current = self.active.load(.acquire);
                if (current < self.max) {
                    if (self.active.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |_| {
                        continue;
                    }
                    return;
                }
                return ThrottleError.GlobalStreamLimitExceeded;
            }
        };

        // Woken by signal — try to claim a slot.
        while (true) {
            const current = self.active.load(.acquire);
            if (current < self.max) {
                if (self.active.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |_| {
                    continue;
                }
                return;
            }
            // Lost the race to another thread that was also waiting.
            // Fall through to return the error.
            return ThrottleError.GlobalStreamLimitExceeded;
        }
    }

    /// Release a slot when a stream handler thread exits.
    /// Must be called exactly once for each successful `acquire`.
    pub fn release(self: *GlobalStreamThrottle) void {
        const prev = self.active.fetchSub(1, .release);
        std.debug.assert(prev > 0); // underflow guard

        // Wake one waiter (if any) so it can claim the freed slot.
        self.mu.lock();
        defer self.mu.unlock();
        self.cv.signal();
    }

    /// Return the current number of active stream handler threads.
    pub fn count(self: *const GlobalStreamThrottle) u32 {
        return self.active.load(.acquire);
    }
};

pub const ActiveStreamRegistry = struct {
    mu: std.Thread.Mutex = .{},
    len: usize = 0,
    ids: [max_total_streams_per_connection]u64 = [_]u64{0} ** max_total_streams_per_connection,

    pub fn register(self: *ActiveStreamRegistry, stream_id: u64) RegistryError!bool {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.containsLocked(stream_id)) return false;
        if (self.len == self.ids.len) return error.StreamRegistryFull;

        self.ids[self.len] = stream_id;
        self.len += 1;
        return true;
    }

    pub fn unregister(self: *ActiveStreamRegistry, stream_id: u64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.unregisterLocked(stream_id);
    }

    pub fn contains(self: *ActiveStreamRegistry, stream_id: u64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.containsLocked(stream_id);
    }

    pub fn count(self: *ActiveStreamRegistry) usize {
        self.mu.lock();
        defer self.mu.unlock();
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
