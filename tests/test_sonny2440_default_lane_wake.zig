// SONNY-2440 regression: work submitted to an idle geode pool starts at once.
//
// thread_pool 0.2.10 coalesces submitter wake-ups (`Core.enqueueTask`,
// src/pool.zig:1582-1592): only every `wake_coalesce_batch`-th submit (32 by
// default) scans for a parked worker and signals it. Its comment assumes an
// idle worker sees the queued work through the park handshake, but that
// covers only a worker about to park: one already parked sleeps until its
// `idle_park_after_ns` timer expires, which geode sets to 500 ms
// (src/transport/thread_pool.zig). So on an idle geode pool a submitted task
// (a connection or stream handler, a background job) that was not the 32nd
// waited up to half a second for a worker while others sat parked. geode's
// pools now wake on every submit (`ThreadPoolConfig.wake_coalesce_batch`).
//
// Through geode's real pool wrapper with its default configuration: 8
// workers, 7 serving the default lane, all parked; 7 default-lane tasks that
// each hold until all 7 have started. (The 8th task, which only the blocking
// worker could run, is test-sonny2440-blocking-worker-fallback: that half is
// in thread_pool itself.)
//
// CANARY: REQ=REQ-SONNY-2440-DEFAULT-LANE-WAKE; FEATURE="ThreadPool"; ASPECT=ParkedWorkerWake; STATUS=TESTED; TEST=tests/test_sonny2440_default_lane_wake.zig; OWNER=transport; UPDATED=2026-11-13

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const thread_pool = @import("transport/thread_pool");
const ThreadPool = thread_pool.ThreadPool;

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

/// Far below the 500 ms park this catches; room for a loaded host's wake-up
/// latency.
const start_bound_ns: u64 = 150 * std.time.ns_per_ms;

test "SONNY-2440: every default-lane task submitted to an idle pool starts without waiting for a park timeout" {
    const workers: u32 = 8;
    const default_workers: u32 = workers - 1; // one blocking-lane worker by default
    const pool = try ThreadPool.init(testing.allocator, .{ .num_threads = workers, .queue_capacity = 64 });
    defer pool.deinit();

    var worst_ns: u64 = 0;
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        // Every worker idle and parked.
        sleepNs(50 * std.time.ns_per_ms);

        var b: Barrier = .{};
        const submitted_at = monoNanos();
        var i: u32 = 0;
        while (i < default_workers) : (i += 1) {
            try testing.expect(pool.submit(.{ .context = @ptrCast(&b), .callback = holdTask }));
        }
        const deadline = monoNanos() + 10 * std.time.ns_per_s;
        while (b.started.load(.acquire) < default_workers and monoNanos() < deadline) sleepNs(std.time.ns_per_ms / 4);
        const started = b.started.load(.acquire);
        b.release.store(true, .release);
        const drain = monoNanos() + 20 * std.time.ns_per_s;
        while (b.finished.load(.acquire) < started and monoNanos() < drain) sleepNs(std.time.ns_per_ms);

        try testing.expectEqual(default_workers, started);
        worst_ns = @max(worst_ns, b.last_start_ns.load(.acquire) -| submitted_at);
    }

    if (worst_ns > start_bound_ns) {
        std.debug.print("a default-lane task started {d} ms after it was submitted to an idle pool (bound {d} ms): a parked worker was not woken for it\n", .{ worst_ns / std.time.ns_per_ms, start_bound_ns / std.time.ns_per_ms });
        return error.ParkedWorkerNotWoken;
    }
}
