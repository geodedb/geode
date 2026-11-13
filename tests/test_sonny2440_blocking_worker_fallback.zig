// SONNY-2440 reproduction (intentionally RED until the thread_pool dependency
// is fixed; see docs/KNOWN_TEST_ISSUES.md).
//
// geode's pools reserve one blocking-lane worker by default
// (`ThreadPoolConfig.blocking_workers = 1`), and thread_pool documents that an
// idle blocking worker always helps the default lane (`rebalanceLane`). But a
// default-lane submit only wakes default-lane workers (thread_pool 0.2.10
// `Core.scanAndWake`, src/pool.zig:1780-1801), and a parking blocking worker
// checks only its own lane's queue counter before it sleeps
// (`Core.idle`, src/pool.zig:2492-2493). So when every default-lane worker is
// busy, a further default-lane task waits for the blocking worker's timed
// park to expire: geode sets `idle_park_after_ns` to 500 ms
// (src/transport/thread_pool.zig), so up to half a second.
//
// Through geode's real pool wrapper with its default configuration: 8
// workers (7 default-lane, 1 blocking), all parked; 8 default-lane tasks that
// each hold until all 8 have started. The 8th can only run on the blocking
// worker, and must start promptly.
//
// CANARY: REQ=REQ-SONNY-2440-BLOCKING-WORKER-FALLBACK; FEATURE="ThreadPool"; ASPECT=DefaultLaneFallbackLatency; STATUS=IMPL; TEST=tests/test_sonny2440_blocking_worker_fallback.zig; OWNER=transport; UPDATED=2026-11-13

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const thread_pool = @import("transport/thread_pool");
const ThreadPool = thread_pool.ThreadPool;
const WorkItem = thread_pool.WorkItem;

fn monoNanos() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn sleepNs(ns: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ns), .awake) catch {};
}

const Barrier = struct {
    started: std.atomic.Value(u32) = .init(0),
    finished: std.atomic.Value(u32) = .init(0),
    release: std.atomic.Value(bool) = .init(false),
    last_start_ns: std.atomic.Value(u64) = .init(0),
};

fn holdTask(ctx: *anyopaque) void {
    const b: *Barrier = @ptrCast(@alignCast(ctx));
    _ = b.last_start_ns.fetchMax(monoNanos(), .acq_rel);
    _ = b.started.fetchAdd(1, .acq_rel);
    const deadline = monoNanos() + 15 * std.time.ns_per_s;
    while (!b.release.load(.acquire) and monoNanos() < deadline) sleepNs(std.time.ns_per_ms);
    _ = b.finished.fetchAdd(1, .acq_rel);
}

/// The ticket's bound is 50 ms. 150 ms leaves room for a loaded host's
/// wake-up latency and is still well below the 500 ms park this catches.
const fallback_bound_ns: u64 = 150 * std.time.ns_per_ms;

test "SONNY-2440: with every default-lane worker busy, a default-lane task starts on the blocking worker promptly" {
    const workers: u32 = 8;
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = workers, .queue_capacity = 64 });
    defer pool.deinit();

    var worst_ns: u64 = 0;
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        // Every worker idle and parked (a fresh park timer each).
        sleepNs(50 * std.time.ns_per_ms);

        var b: Barrier = .{};
        const submitted_at = monoNanos();
        var i: u32 = 0;
        while (i < workers) : (i += 1) {
            try testing.expect(pool.submit(.{ .context = @ptrCast(&b), .callback = holdTask }));
        }
        const deadline = monoNanos() + 10 * std.time.ns_per_s;
        while (b.started.load(.acquire) < workers and monoNanos() < deadline) sleepNs(std.time.ns_per_ms / 4);
        const started = b.started.load(.acquire);
        b.release.store(true, .release);
        const drain = monoNanos() + 20 * std.time.ns_per_s;
        while (b.finished.load(.acquire) < started and monoNanos() < drain) sleepNs(std.time.ns_per_ms);

        try testing.expectEqual(workers, started);
        const waited = b.last_start_ns.load(.acquire) -| submitted_at;
        worst_ns = @max(worst_ns, waited);
    }

    if (worst_ns > fallback_bound_ns) {
        std.debug.print("the 8th default-lane task started {d} ms after it was submitted (bound {d} ms): the blocking worker was not woken for it\n", .{ worst_ns / std.time.ns_per_ms, fallback_bound_ns / std.time.ns_per_ms });
        return error.BlockingWorkerFallbackLate;
    }
}
