// Task #31: QUIC stream multiplex hang — Level 1 pool-level regression.
//
// Root cause (see docs/performance/2026-04-24-sharding/TASK-31-TRIAGE.md):
// `src/transport/thread_pool.zig:216` hard-codes `blocking_workers = 1` and
// `submit()` routes every task to `.lane = .blocking`.  `src/server/quic_
// connection_handler.zig:1572` submits every accepted stream via that
// same `submit()`.  Result: each per-QUIC-connection pool (configured with
// `num_threads = 4`) can run only **1 inline + 1 blocking = 2** concurrent
// stream handlers.  Additional streams sit in `blocking_inject` until a
// running handler closes, producing the user-visible hang observed at
// `completed=2/4` in the msft-graph workload.
//
// This test pins the API contract directly: a 4-thread stream pool
// receiving 4 tasks via `submit()` MUST run all 4 in parallel within a
// bounded (1 s) window, then drain.  Pre-fix this test times out with
// `started ≤ 2`; post-fix it releases cleanly at `started == 4` and
// `max_concurrent == 4`.
//
// Build wiring: see build.zig.  Imports `transport/thread_pool` (same
// module as `test_thread_pool_lane_parallelism.zig`) so it exercises the
// real geode wrapper — not the external pool directly.

const std = @import("std");
const testing = std.testing;
const thread_pool = @import("transport/thread_pool");
const ThreadPool = thread_pool.ThreadPool;
const WorkItem = thread_pool.WorkItem;

// Zig 0.16 compat: Timer removed, use clock_gettime directly.
fn monoNanos() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// Zig 0.16 compat: std.Thread.sleep removed.
fn sleepNs(ns: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

const BarrierCtx = struct {
    started_count: std.atomic.Value(u32),
    finished_count: std.atomic.Value(u32),
    release: std.atomic.Value(bool),
    max_concurrent: std.atomic.Value(u32),
    current_concurrent: std.atomic.Value(u32),
};

fn barrierTask(ctx: *anyopaque) void {
    const c: *BarrierCtx = @ptrCast(@alignCast(ctx));
    _ = c.started_count.fetchAdd(1, .acq_rel);

    // Track peak concurrent in-flight count.
    const now = c.current_concurrent.fetchAdd(1, .acq_rel) + 1;
    var prev_max = c.max_concurrent.load(.acquire);
    while (now > prev_max) {
        if (c.max_concurrent.cmpxchgWeak(prev_max, now, .acq_rel, .acquire)) |actual| {
            prev_max = actual;
        } else {
            break;
        }
    }

    // Spin until release, bounded to ~5 s so a buggy pool fails the test
    // rather than wedging the test runner.
    const deadline = monoNanos() + 5 * std.time.ns_per_s;
    while (!c.release.load(.acquire)) {
        if (monoNanos() > deadline) break;
        sleepNs(1 * std.time.ns_per_ms);
    }
    _ = c.current_concurrent.fetchSub(1, .acq_rel);
    _ = c.finished_count.fetchAdd(1, .acq_rel);
}

// ──────────────────────────────────────────────────────────────────────
// Regression: the exact shape of the Task #31 bug.
// Issue: blocking_workers=1 starves 4-thread stream pool via submit().
// Expected (post-fix): 4 tasks submitted via submit() all run in parallel.
// Pre-fix: started stalls at 2 (1 inline spawn + 1 blocking worker), the
// signaller flips release, and started never reaches 4 before the 1 s
// barrier deadline.
// ──────────────────────────────────────────────────────────────────────
test "task31_regression: submit() — 4 tasks on 4-thread pool must run concurrently" {
    // Mirror the per-connection stream pool config at
    // src/server/quic_connection_handler.zig:1994 (stream_pool_size = 4).
    const num_workers: usize = 4;
    const pool = try ThreadPool.init(testing.allocator, .{
        .num_threads = num_workers,
        .queue_capacity = 64,
    });
    defer pool.deinit();

    const n: u32 = @intCast(num_workers);

    var ctx = BarrierCtx{
        .started_count = std.atomic.Value(u32).init(0),
        .finished_count = std.atomic.Value(u32).init(0),
        .release = std.atomic.Value(bool).init(false),
        .max_concurrent = std.atomic.Value(u32).init(0),
        .current_concurrent = std.atomic.Value(u32).init(0),
    };

    // Route through the EXACT API used by the QUIC stream handler:
    // `submit()`, not `submitDefault`.  This is the pre-fix fail path.
    var submitted: u32 = 0;
    while (submitted < n) : (submitted += 1) {
        const ok = pool.submit(.{
            .context = @ptrCast(&ctx),
            .callback = barrierTask,
        });
        try testing.expect(ok);
    }

    // Wait up to 1 s for all N tasks to reach the barrier.  If `submit`
    // still serializes behind the 1-wide blocking lane, started_count
    // caps at 1 (or at 2 if the scheduler happens to run one inline)
    // and this loop times out.
    const deadline = monoNanos() + 1 * std.time.ns_per_s;
    while (ctx.started_count.load(.acquire) < n) {
        if (monoNanos() > deadline) break;
        sleepNs(1 * std.time.ns_per_ms);
    }

    const started_before_release = ctx.started_count.load(.acquire);
    const peak_concurrent_before_release = ctx.max_concurrent.load(.acquire);

    // Release the barrier and wait for all in-flight tasks to finish
    // (otherwise defer pool.deinit() blocks for 2 s on the stragglers).
    ctx.release.store(true, .release);
    const drain_deadline = monoNanos() + 5 * std.time.ns_per_s;
    while (ctx.finished_count.load(.acquire) < started_before_release) {
        if (monoNanos() > drain_deadline) break;
        sleepNs(1 * std.time.ns_per_ms);
    }

    // Diagnostic output — aids the bug fixer in confirming the expected
    // red-to-green transition.
    std.debug.print(
        "\ntask31: started_before_release={} peak_concurrent_before_release={} (expected {} for both)\n",
        .{ started_before_release, peak_concurrent_before_release, n },
    );

    // THE LOAD-BEARING ASSERTIONS.  Pre-fix: started_before_release < n,
    // peak_concurrent_before_release <= 1.  Post-fix: both == n.
    try testing.expectEqual(n, started_before_release);
    try testing.expect(peak_concurrent_before_release >= n);
}

// ──────────────────────────────────────────────────────────────────────
// Boundary case 1: a single stream on a 4-thread pool must still run.
// Ensures the fix doesn't accidentally require N-way parallelism to make
// progress at all.
// ──────────────────────────────────────────────────────────────────────
test "task31_edge: submit() — single task on 4-thread pool drains" {
    const pool = try ThreadPool.init(testing.allocator, .{
        .num_threads = 4,
        .queue_capacity = 64,
    });
    defer pool.deinit();

    var ctx = BarrierCtx{
        .started_count = std.atomic.Value(u32).init(0),
        .finished_count = std.atomic.Value(u32).init(0),
        .release = std.atomic.Value(bool).init(true), // run-to-completion
        .max_concurrent = std.atomic.Value(u32).init(0),
        .current_concurrent = std.atomic.Value(u32).init(0),
    };

    try testing.expect(pool.submit(.{
        .context = @ptrCast(&ctx),
        .callback = barrierTask,
    }));

    const deadline = monoNanos() + 1 * std.time.ns_per_s;
    while (ctx.finished_count.load(.acquire) < 1) {
        if (monoNanos() > deadline) break;
        sleepNs(1 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(u32, 1), ctx.finished_count.load(.acquire));
}

// ──────────────────────────────────────────────────────────────────────
// Boundary case 2: 8 tasks on a 4-thread pool — extra tasks must still
// all complete, even if only 4 run concurrently at peak.  Exercises the
// queue-drain path.
// ──────────────────────────────────────────────────────────────────────
test "task31_edge: submit() — 8 tasks on 4-thread pool all complete" {
    const pool = try ThreadPool.init(testing.allocator, .{
        .num_threads = 4,
        .queue_capacity = 64,
    });
    defer pool.deinit();

    const n: u32 = 8;
    var ctx = BarrierCtx{
        .started_count = std.atomic.Value(u32).init(0),
        .finished_count = std.atomic.Value(u32).init(0),
        .release = std.atomic.Value(bool).init(true), // drain without barrier
        .max_concurrent = std.atomic.Value(u32).init(0),
        .current_concurrent = std.atomic.Value(u32).init(0),
    };

    var submitted: u32 = 0;
    while (submitted < n) : (submitted += 1) {
        try testing.expect(pool.submit(.{
            .context = @ptrCast(&ctx),
            .callback = barrierTask,
        }));
    }

    const deadline = monoNanos() + 5 * std.time.ns_per_s;
    while (ctx.finished_count.load(.acquire) < n) {
        if (monoNanos() > deadline) break;
        sleepNs(1 * std.time.ns_per_ms);
    }
    try testing.expectEqual(n, ctx.finished_count.load(.acquire));
    // Post-fix we expect peak concurrency to be >= 2 (running through
    // the queue) — we don't assert == 4 here since scheduling can vary.
    try testing.expect(ctx.max_concurrent.load(.acquire) >= 2);
}
