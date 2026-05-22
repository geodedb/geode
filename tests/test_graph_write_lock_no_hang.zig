// Regression test for the intermittent server-side write-lock HANG
// triaged 2026-05-22 on `geodetestlab-cli/specs/gap_0257_orderby_large_resultset.yml`.
//
// Symptom: 1-in-~30 runs, a plain multi-pattern `CREATE (:L {..}),(...)`
// query hung for the full client timeout and the server task never
// completed.  `gdb` on the live server (captured twice) showed:
//
//   * one connection-handler thread parked in
//     `Io.Semaphore.waitUncancelable` reached from
//     `Io.RwLock.lockUncancelable` <- `acquireGraphWriteLockCancelable`
//   * the periodic checkpoint thread (`checkpointAll`, which takes the
//     SAME `mg.rwlock` SHARED) parked on the RwLock's internal mutex
//   * NO thread holding the lock and NO reader active
//
// Root cause: `acquireGraphWriteLockCancelable` routed generous-deadline
// writers through `mg.rwlock.lockUncancelable`, which — if it observed a
// reader at the instant it marked `is_writing` — parks UNBOUNDEDLY on the
// RwLock's internal counting semaphore waiting for a `post()` from the
// last reader's `unlockShared`.  A single missed wakeup wedges the writer
// forever; it keeps the RwLock's internal mutex, and every later reader
// and writer (the next checkpoint, every queued connection handler)
// stalls behind it.
//
// Fix: `acquireGraphWriteLockCancelable` (and the non-cancelable
// `acquireGraphWriteLock` / `acquireWholeGraphExclusive`) now re-probe via
// `tryLock`, which reads `rl.state` directly and touches no semaphore — so
// a lost wakeup can never wedge the writer.  The cancelable variant still
// honours its deadline.
//
// Contract pinned here: with a long-lived SHARED reader repeatedly
// acquiring/releasing the per-graph rwlock (modelling the checkpoint
// loop), a writer with a generous deadline acquires the lock within a
// bounded time and NEVER hangs.  A watchdog bounds the test so a
// regression fails loudly instead of hanging CI.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;

fn monoNanos() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn sleepNs(ns: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

const ReaderChurnCtx = struct {
    graph_name: []const u8,
    stop: *std.atomic.Value(u32),
};

// Models the periodic checkpoint loop: take the per-graph SHARED lock,
// hold it briefly, release, repeat.  This is exactly the reader traffic
// that, paired with the old unbounded-semaphore writer wait, produced the
// wedge.
fn readerChurn(ctx: *ReaderChurnCtx) void {
    while (ctx.stop.load(.acquire) == 0) {
        const h = graph_store.acquireGraphReadLockTagged(ctx.graph_name, .misc);
        sleepNs(300 * std.time.ns_per_us);
        graph_store.releaseGraphLock(h);
        sleepNs(150 * std.time.ns_per_us);
    }
}

const WriterCtx = struct {
    graph_name: []const u8,
    iterations: u32,
    completed: *std.atomic.Value(u32),
    deadline_per_acquire_ns: u64,
};

// Repeatedly acquire the per-graph WRITE lock with a generous deadline
// (mirrors the connection-handler mutation path).  Each acquisition must
// either succeed or return a clean `error.Deadline` — never hang.
fn writerLoop(ctx: *WriterCtx) void {
    var i: u32 = 0;
    while (i < ctx.iterations) : (i += 1) {
        const result = graph_store.acquireGraphWriteLockCancelable(
            ctx.graph_name,
            monoNanos() + ctx.deadline_per_acquire_ns,
        );
        if (result) |h| {
            // Brief critical section, like a small CREATE batch.
            sleepNs(200 * std.time.ns_per_us);
            graph_store.releaseGraphLock(h);
        } else |_| {
            // error.Deadline is acceptable — it is a clean, retryable
            // outcome, NOT a hang.  Keep going.
        }
        _ = ctx.completed.fetchAdd(1, .monotonic);
    }
}

test "graph write lock never hangs against a churning shared reader" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    const graph_name = "test_graph_write_lock_no_hang";
    store.createGraph(graph_name) catch |err| switch (err) {
        error.GraphAlreadyExists => {},
        else => return err,
    };

    var stop_readers = std.atomic.Value(u32).init(0);
    var reader_ctx = ReaderChurnCtx{
        .graph_name = graph_name,
        .stop = &stop_readers,
    };

    const num_writers = 4;
    const iters_per_writer: u32 = 25;
    var writer_completed = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** num_writers;
    var writer_ctxs: [num_writers]WriterCtx = undefined;
    for (&writer_ctxs, 0..) |*wc, i| {
        wc.* = .{
            .graph_name = graph_name,
            .iterations = iters_per_writer,
            .completed = &writer_completed[i],
            // Generous per-acquire deadline — this is the regime that
            // routed through the wedging `lockUncancelable` path before
            // the fix.
            .deadline_per_acquire_ns = 5 * std.time.ns_per_s,
        };
    }

    // Spawn two SHARED-reader churn threads + N writer threads.
    var reader_threads: [2]std.Thread = undefined;
    for (&reader_threads) |*t| t.* = try std.Thread.spawn(.{}, readerChurn, .{&reader_ctx});

    var writer_threads: [num_writers]std.Thread = undefined;
    for (&writer_threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, writerLoop, .{&writer_ctxs[i]});
    }

    // Watchdog: every writer doing 25 iterations of a ~200us critical
    // section, even fully serialised behind reader churn, completes well
    // within 30 s.  Before the fix, a single wedged writer never
    // incremented its counter again and this loop times out.
    const total_expected: u32 = num_writers * iters_per_writer;
    const watchdog_deadline = monoNanos() + 30 * std.time.ns_per_s;
    var all_done = false;
    while (monoNanos() < watchdog_deadline) {
        var done: u32 = 0;
        for (&writer_completed) |*c| done += c.load(.acquire);
        if (done >= total_expected) {
            all_done = true;
            break;
        }
        sleepNs(20 * std.time.ns_per_ms);
    }

    stop_readers.store(1, .release);
    for (&reader_threads) |t| t.join();
    for (&writer_threads) |t| t.join();

    if (!all_done) {
        var done: u32 = 0;
        for (&writer_completed) |*c| done += c.load(.acquire);
        std.debug.print(
            "WRITE-LOCK HANG REGRESSION: only {d}/{d} write-lock " ++
                "acquisitions completed within the 30 s watchdog. A writer " ++
                "is wedged inside acquireGraphWriteLockCancelable — the " ++
                "per-graph rwlock writer parked unboundedly on the RwLock " ++
                "semaphore (lost-wakeup wedge).\n",
            .{ done, total_expected },
        );
        return error.GraphWriteLockHang;
    }
}
