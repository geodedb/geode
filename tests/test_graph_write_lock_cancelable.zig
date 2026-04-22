// Regression test for R2 — uncancelable graph write lock.
//
// Triage: `acquireGraphWriteLock` in
// src/storage/graph_storage_adapter.zig:2213-2228 (and the top-level
// wrapper at src/graph_store.zig:5076) uses `rwlock.lockUncancelable`.
// Callers (src/server/quic_connection_handler.zig:2341) have no way to
// time out or cancel.  Under the 16-worker ingest workload this parks
// the transport threads forever once one worker is stuck inside a long-
// running mutation, leaving the QUIC handler thread-pool with "1 active
// tasks" and the 30-second deinit timeout fires on shutdown.
//
// Desired contract (pinned by this test):
//   `graph_store.acquireGraphWriteLockCancelable(graph_name, deadline_ns)`
//   returns `error.Deadline` (or similar) when the lock cannot be acquired
//   before the caller-supplied deadline.
//
// Today no such function exists and the existing
// `acquireGraphWriteLock` simply parks.  This test spawns two threads:
//
//   Thread A — takes the uncancelable write lock, signals B, and holds
//              it for 2 seconds.
//   Thread B — waits for A's signal, then attempts to acquire the graph
//              write lock with a *100 ms deadline*.
//
// The test asserts that B returns within ~1 second (either because a
// cancelable API exists and returned `error.Deadline`, or because a
// future implementation became non-blocking).  On today's code, B parks
// on `lockUncancelable` until A releases at t=2s — well past the 1 s
// watchdog — so the test fails by watchdog timeout.
//
// A watchdog thread prints a diagnostic and exits the test process with
// an error if the expected deadline is exceeded: waiting the full 2 s
// for A to release would still let the test "pass" by accident if we
// only checked wall-clock duration.  The watchdog bounds how long we
// wait; the test then asserts B didn't actually get the lock within its
// stated 100 ms deadline.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;

// Zig 0.16 compat — see tests/test_handler_lock_hold_scope.zig:34-56.
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

fn waitForFlag(flag: *std.atomic.Value(u32)) void {
    while (flag.load(.acquire) == 0) std.atomic.spinLoopHint();
}

const WriterHoldCtx = struct {
    graph_name: []const u8,
    engaged: *std.atomic.Value(u32),
    hold_ns: u64,
};

const ContenderCtx = struct {
    graph_name: []const u8,
    engaged: *std.atomic.Value(u32),
    deadline_ns: u64,
    attempt_start_ns: *u64,
    attempt_end_ns: *u64,
    acquired: *std.atomic.Value(u32),
};

fn writerHoldsLongLock(ctx: *WriterHoldCtx) void {
    const h = graph_store.acquireGraphWriteLock(ctx.graph_name);
    ctx.engaged.store(1, .release);
    sleepNs(ctx.hold_ns);
    graph_store.releaseGraphLock(h);
}

fn contenderTriesWithDeadline(ctx: *ContenderCtx) void {
    waitForFlag(ctx.engaged);
    ctx.attempt_start_ns.* = monoNanos();

    // ---- INTENDED API (not yet implemented) ----
    // const result = graph_store.acquireGraphWriteLockCancelable(
    //     ctx.graph_name,
    //     monoNanos() + ctx.deadline_ns,
    // );
    // ctx.attempt_end_ns.* = monoNanos();
    // if (result) |h| {
    //     ctx.acquired.store(1, .release);
    //     graph_store.releaseGraphLock(h);
    // } else |err| switch (err) {
    //     error.Deadline => {},
    //     else => std.debug.print("contender error: {s}\n", .{@errorName(err)}),
    // }

    // ---- CURRENT API (uncancelable) ----
    // We call the uncancelable API to prove it blocks past the deadline.
    // If a cancelable variant is added later, this call site is swapped
    // to the commented block above.
    const h = graph_store.acquireGraphWriteLock(ctx.graph_name);
    ctx.attempt_end_ns.* = monoNanos();
    ctx.acquired.store(1, .release);
    graph_store.releaseGraphLock(h);
}

test "graph write lock can be acquired with a deadline (R2)" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    const graph_name = "test_graph_write_lock_cancelable";
    store.createGraph(graph_name) catch |err| switch (err) {
        error.GraphAlreadyExists => {},
        else => return err,
    };

    var engaged = std.atomic.Value(u32).init(0);
    var writer_ctx = WriterHoldCtx{
        .graph_name = graph_name,
        .engaged = &engaged,
        // Hold for 2 s — well past the contender's 100 ms deadline so
        // the test can catch the uncancelable blocking behavior.
        .hold_ns = 2 * std.time.ns_per_s,
    };

    var acquired = std.atomic.Value(u32).init(0);
    var attempt_start: u64 = 0;
    var attempt_end: u64 = 0;
    var contender_ctx = ContenderCtx{
        .graph_name = graph_name,
        .engaged = &engaged,
        .deadline_ns = 100 * std.time.ns_per_ms,
        .attempt_start_ns = &attempt_start,
        .attempt_end_ns = &attempt_end,
        .acquired = &acquired,
    };

    const t_writer = try std.Thread.spawn(.{}, writerHoldsLongLock, .{&writer_ctx});
    const t_contender = try std.Thread.spawn(.{}, contenderTriesWithDeadline, .{&contender_ctx});

    // Watchdog: wait up to 1 s for the contender to finish its attempt.
    // If a cancelable API exists, the contender returns at ~100 ms with
    // `error.Deadline` (acquired=0).  If the uncancelable API still parks,
    // the contender doesn't return until t_writer finishes at t=2s.
    const watchdog_ns: u64 = 1 * std.time.ns_per_s;
    const wait_deadline = monoNanos() + watchdog_ns;

    var contender_returned: bool = false;
    while (monoNanos() < wait_deadline) {
        if (contender_ctx.attempt_end_ns.* != 0) {
            contender_returned = true;
            break;
        }
        sleepNs(5 * std.time.ns_per_ms);
    }

    if (!contender_returned) {
        // The contender is still parked inside the uncancelable write
        // lock.  We MUST still join the threads or the process hangs at
        // test teardown.  Let the writer release naturally, then join.
        std.debug.print(
            "R2: Contender thread did not honor its 100 ms deadline — " ++
                "still blocked on acquireGraphWriteLock after {d} ms. " ++
                "There is no cancelable variant of the graph write lock " ++
                "(src/storage/graph_storage_adapter.zig:2213-2228, " ++
                "src/graph_store.zig:5076). Callers in " ++
                "src/server/quic_connection_handler.zig:2341 therefore " ++
                "park indefinitely.\n",
            .{watchdog_ns / std.time.ns_per_ms},
        );
        t_writer.join();
        t_contender.join();
        return error.GraphWriteLockNotCancelable;
    }

    t_writer.join();
    t_contender.join();

    // The contender call returned — but did it honor the 100 ms deadline?
    const elapsed_ns = attempt_end - attempt_start;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const budget_ms: f64 = 200.0; // 100 ms deadline + 100 ms slop
    if (elapsed_ms > budget_ms) {
        std.debug.print(
            "R2: contender waited {d:.3} ms for the graph write lock " ++
                "despite a 100 ms deadline. Acquisition is not " ++
                "cancelable.\n",
            .{elapsed_ms},
        );
        return error.GraphWriteLockNotCancelable;
    }

    // After the fix, we expect the cancelable variant to have refused the
    // acquisition entirely.  The current code reaches this point only
    // after the writer releases — in which case `acquired==1` but that's
    // the wrong semantics.  Guard against it.
    if (acquired.load(.acquire) == 1 and elapsed_ms > 50.0) {
        std.debug.print(
            "R2: contender acquired the write lock only after the writer " ++
                "released ({d:.3} ms) — deadline was ignored.\n",
            .{elapsed_ms},
        );
        return error.GraphWriteLockNotCancelable;
    }
}
