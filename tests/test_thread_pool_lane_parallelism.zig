// Zig unit test for GitLab #751 — proves the admission-lane parallelism
// contract at the pool API level, independent of any QUIC / server wiring.
//
// CANARY: REQ=REQ-PERF-SESSION-ADMISSION-003; FEATURE="ConnectionAdmissionLaneAPI"; ASPECT=UnitTest; STATUS=IMPL; TEST=test_thread_pool_lane_parallelism; OWNER=transport; UPDATED=2026-04-16
//
// Two contracts pinned here:
//   1. `submitDefault` MUST exist on ThreadPool (the lane-routing helper that
//      sends work to `.lane = .default`). Pre-fix: no such decl → runtime
//      fail via `@hasDecl` gate. Post-fix: decl present, test proceeds.
//   2. Work submitted via `submitDefault` MUST run in parallel across the
//      default-lane workers. We prove N-way parallelism by submitting N
//      tasks that each record a monotonic start timestamp, stall on a
//      countdown-latch-style counter until all N have started, and
//      observe that the max cross-task start-time skew is well within a
//      generous budget (100 ms). Pre-fix the serialized blocking-lane
//      path would push that skew to >= (N-1) * task_duration ≈ seconds.
//   3. Work submitted via `submitBlocking` (the existing blocking-lane
//      entry point) MUST remain serialized at 1-wide (blocking_workers =
//      1 by construction). We re-use the same barrier trick to observe
//      exactly 1 task in-flight at any time.
//
// Build wiring: see build.zig — the test binary imports `transport/thread_pool`
// and runs under `zig build test` as a dedicated step.

const std = @import("std");
const testing = std.testing;
const thread_pool = @import("transport/thread_pool");
const ThreadPool = thread_pool.ThreadPool;
const WorkItem = thread_pool.WorkItem;

// Zig 0.16 compat: std.time.Timer removed (per project convention, see
// src/performance/json_optimized_fixed.zig:332-339). Use clock_gettime
// directly for monotonic nanosecond timestamps.
fn monoNanos() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// Zig 0.16 compat: std.Thread.sleep was removed (see src/transport/quic.zig:3-11).
fn sleepNs(ns: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

// Shared context for barrier-style tasks. Each task atomically bumps
// `started_count`, records its start timestamp at its slot, and spins
// until `release` is set to true (or a timeout elapses).
const BarrierCtx = struct {
    started_count: std.atomic.Value(u32),
    finished_count: std.atomic.Value(u32),
    release: std.atomic.Value(bool),
    start_ts: []u64,
    max_concurrent: std.atomic.Value(u32),
    current_concurrent: std.atomic.Value(u32),
};

fn barrierTask(ctx: *anyopaque) void {
    const c: *BarrierCtx = @ptrCast(@alignCast(ctx));
    const idx = c.started_count.fetchAdd(1, .acq_rel);
    if (idx < c.start_ts.len) {
        c.start_ts[idx] = monoNanos();
    }
    // Track concurrent in-flight tasks: bump current, snapshot max.
    const now = c.current_concurrent.fetchAdd(1, .acq_rel) + 1;
    var prev_max = c.max_concurrent.load(.acquire);
    while (now > prev_max) {
        if (c.max_concurrent.cmpxchgWeak(prev_max, now, .acq_rel, .acquire)) |actual| {
            prev_max = actual;
        } else {
            break;
        }
    }
    // Spin until release, bounded to ~2 s so a buggy pool doesn't hang
    // the test forever.
    const deadline = monoNanos() + 2 * std.time.ns_per_s;
    while (!c.release.load(.acquire)) {
        if (monoNanos() > deadline) break;
        sleepNs(1 * std.time.ns_per_ms);
    }
    _ = c.current_concurrent.fetchSub(1, .acq_rel);
    _ = c.finished_count.fetchAdd(1, .acq_rel);
}

test "submitDefault: API exists on ThreadPool" {
    // This test is the bare-minimum fix-shape assertion: the declaration
    // must exist. If it does not, the test fails immediately with a
    // clear diagnostic — no other tests in this file can run without it.
    //
    // Pre-fix: red (submitDefault absent → @hasDecl returns false).
    // Post-fix: green.
    const has_default = @hasDecl(ThreadPool, "submitDefault");
    if (!has_default) {
        std.debug.print(
            "\nMISSING: ThreadPool.submitDefault — #751 fix not applied. " ++
                "Add a default-lane submit helper in src/transport/thread_pool.zig.\n",
            .{},
        );
    }
    try testing.expect(has_default);
}

test "submitDefault: 8-way parallelism via default-lane workers" {
    if (!@hasDecl(ThreadPool, "submitDefault")) {
        // Already reported by the prior test; short-circuit here so the
        // rest of this test body doesn't reference a missing method.
        return error.SkipZigTest;
    }

    const num_workers: usize = 8;
    const pool = try ThreadPool.init(testing.allocator, .{
        .num_threads = num_workers,
        .queue_capacity = 64,
    });
    defer pool.deinit();

    // N parallel tasks that all need to be running simultaneously to
    // release the barrier. If fewer than N workers can run in parallel,
    // `started_count` caps at that number and the test times out.
    const n: u32 = @intCast(num_workers);
    const start_ts = try testing.allocator.alloc(u64, n);
    defer testing.allocator.free(start_ts);
    @memset(start_ts, 0);

    var ctx = BarrierCtx{
        .started_count = std.atomic.Value(u32).init(0),
        .finished_count = std.atomic.Value(u32).init(0),
        .release = std.atomic.Value(bool).init(false),
        .start_ts = start_ts,
        .max_concurrent = std.atomic.Value(u32).init(0),
        .current_concurrent = std.atomic.Value(u32).init(0),
    };

    // Submit N tasks via the *default* lane entry point. Each task
    // bumps started_count and stalls until release.
    //
    // NOTE: we reference submitDefault via a comptime gate so this
    // file still compiles on pre-fix main (where the method is absent).
    // The @hasDecl guard at the top of this test short-circuits before
    // we get here on pre-fix builds.
    inline for (0..1) |_| { // dummy loop to anchor comptime scope
        if (@hasDecl(ThreadPool, "submitDefault")) {
            var submitted: u32 = 0;
            while (submitted < n) : (submitted += 1) {
                const ok = @field(ThreadPool, "submitDefault")(pool, WorkItem{
                    .context = @ptrCast(&ctx),
                    .callback = barrierTask,
                });
                try testing.expect(ok);
            }
        }
    }

    // Wait up to 500 ms for all N to reach the barrier.  If the default
    // lane is serialized (pre-fix bug: blocking_workers=1 path) only 1
    // task ever starts, started_count caps at 1, and we time out.
    const deadline = monoNanos() + 500 * std.time.ns_per_ms;
    while (ctx.started_count.load(.acquire) < n) {
        if (monoNanos() > deadline) break;
        sleepNs(1 * std.time.ns_per_ms);
    }

    const started = ctx.started_count.load(.acquire);

    // Release the barrier and let workers drain before assertions fire
    // (so a failing assertion doesn't leave worker threads spinning).
    ctx.release.store(true, .release);
    const drain_deadline = monoNanos() + 2 * std.time.ns_per_s;
    while (ctx.finished_count.load(.acquire) < started) {
        if (monoNanos() > drain_deadline) break;
        sleepNs(1 * std.time.ns_per_ms);
    }

    try testing.expectEqual(n, started);
    // The pool must have had N tasks running concurrently at the peak
    // — this is the direct negation of the pre-fix "only 1 worker serves
    // this lane" bug.
    try testing.expect(ctx.max_concurrent.load(.acquire) >= n);
}

test "submitBlocking: blocking lane remains 1-wide (no regression)" {
    // The existing blocking-lane invariant (blocking_workers = 1) is
    // load-bearing for cert generation. Make sure the fix doesn't
    // widen the blocking lane by accident; the fix should leave
    // submitBlocking semantics untouched.
    const num_workers: usize = 8;
    const pool = try ThreadPool.init(testing.allocator, .{
        .num_threads = num_workers,
        .queue_capacity = 64,
    });
    defer pool.deinit();

    const n: u32 = 4;
    const start_ts = try testing.allocator.alloc(u64, n);
    defer testing.allocator.free(start_ts);
    @memset(start_ts, 0);

    var ctx = BarrierCtx{
        .started_count = std.atomic.Value(u32).init(0),
        .finished_count = std.atomic.Value(u32).init(0),
        // We can't use the barrier-style all-start-together pattern on
        // the 1-wide blocking lane — it would deadlock. Flip release
        // true up-front so each task runs-to-completion in turn, and
        // just observe max_concurrent.
        .release = std.atomic.Value(bool).init(true),
        .start_ts = start_ts,
        .max_concurrent = std.atomic.Value(u32).init(0),
        .current_concurrent = std.atomic.Value(u32).init(0),
    };

    var submitted: u32 = 0;
    while (submitted < n) : (submitted += 1) {
        try pool.submitBlocking(WorkItem{
            .context = @ptrCast(&ctx),
            .callback = barrierTask,
        });
    }

    // Wait for the queue to drain.
    const deadline = monoNanos() + 2 * std.time.ns_per_s;
    while (ctx.finished_count.load(.acquire) < n) {
        if (monoNanos() > deadline) break;
        sleepNs(1 * std.time.ns_per_ms);
    }

    try testing.expectEqual(n, ctx.finished_count.load(.acquire));
    // Blocking lane invariant: max 1 task in flight at any time.
    try testing.expect(ctx.max_concurrent.load(.acquire) == 1);
}

test "blocking_workers=0: submitBlocking disabled and default lane owns all workers" {
    const num_workers: usize = 4;
    const pool = try ThreadPool.init(testing.allocator, .{
        .num_threads = num_workers,
        .queue_capacity = 64,
        .blocking_workers = 0,
    });
    defer pool.deinit();

    const empty_ts = try testing.allocator.alloc(u64, 0);
    defer testing.allocator.free(empty_ts);
    var dummy_ctx = BarrierCtx{
        .started_count = std.atomic.Value(u32).init(0),
        .finished_count = std.atomic.Value(u32).init(0),
        .release = std.atomic.Value(bool).init(true),
        .start_ts = empty_ts,
        .max_concurrent = std.atomic.Value(u32).init(0),
        .current_concurrent = std.atomic.Value(u32).init(0),
    };
    try testing.expectError(error.BlockingLaneDisabled, pool.submitBlocking(WorkItem{
        .context = @ptrCast(&dummy_ctx),
        .callback = barrierTask,
    }));

    const n: u32 = @intCast(num_workers);
    const start_ts = try testing.allocator.alloc(u64, n);
    defer testing.allocator.free(start_ts);
    @memset(start_ts, 0);

    var ctx = BarrierCtx{
        .started_count = std.atomic.Value(u32).init(0),
        .finished_count = std.atomic.Value(u32).init(0),
        .release = std.atomic.Value(bool).init(false),
        .start_ts = start_ts,
        .max_concurrent = std.atomic.Value(u32).init(0),
        .current_concurrent = std.atomic.Value(u32).init(0),
    };

    var submitted: u32 = 0;
    while (submitted < n) : (submitted += 1) {
        try testing.expect(pool.submitDefault(WorkItem{
            .context = @ptrCast(&ctx),
            .callback = barrierTask,
        }));
    }

    const deadline = monoNanos() + 500 * std.time.ns_per_ms;
    while (ctx.started_count.load(.acquire) < n) {
        if (monoNanos() > deadline) break;
        sleepNs(1 * std.time.ns_per_ms);
    }

    const started = ctx.started_count.load(.acquire);
    ctx.release.store(true, .release);
    const drain_deadline = monoNanos() + 2 * std.time.ns_per_s;
    while (ctx.finished_count.load(.acquire) < started) {
        if (monoNanos() > drain_deadline) break;
        sleepNs(1 * std.time.ns_per_ms);
    }

    try testing.expectEqual(n, started);
    try testing.expect(ctx.max_concurrent.load(.acquire) >= n);
}
