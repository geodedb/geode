// Reproduction/regression tests for GAP-0753 — handler lock-hold scope.
//
// Triage:  docs/superpowers/plans/2026-04-18-match-qps-close-gap.md (Task 1)
// Summary: After GAP-0752 the handler takes the shared graph read lock for
//          non-mutating queries, but it still holds that lock across parse +
//          plan + execute + row materialization (~30 ms per 500-node
//          property lookup).  ReadView / QueryReadSession already provide
//          epoch-safe snapshot isolation, so the lock only needs to cover
//          snapshot capture (<1 ms).
//
// Tests:
//   Test A — two threads acquire the shared read lock back-to-back.  Even
//            though a single lock can host many readers concurrently, this
//            test confirms the *scope* of the hold: thread 1 takes the lock,
//            signals thread 2 via an atomic flag, stalls for 30 ms, and
//            releases.  Thread 2, which waits on the signal, must acquire
//            in < 1 ms because the shared reader lock allows concurrent
//            entry.
//
//   Test B — exercises the full handler seam: a writer thread holds the
//            graph write lock for a simulated 30 ms execution window, and a
//            reader thread attempts to go through `snapshotUnderReadLock`.
//            After GAP-0753, the reader's *lock-hold scope* is bounded by
//            the snapshot phase (<10 ms) even though the write lock keeps
//            the read itself waiting.  The simulated "execute" phase runs
//            AFTER snapshotUnderReadLock returns — i.e. outside the lock.
//
// CANARY: REQ=REQ-PERF-HANDLER-LOCK-HOLD-001; FEATURE="HandlerLockHoldScope"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_handler_lock_hold_scope.zig:1; OWNER=transport; UPDATED=2026-04-18

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;

// Zig 0.16 compat: std.time.Timer / std.time.nanoTimestamp were removed.
// Use clock_gettime directly for monotonic nanosecond timestamps (mirrors
// tests/test_thread_pool_lane_parallelism.zig:34-38).
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
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ns), .awake) catch {};
}

fn waitForFlag(flag: *std.atomic.Value(u32)) void {
    while (flag.load(.acquire) == 0) std.atomic.spinLoopHint();
}

// -------------------------------------------------------------------
// Test A — concurrent shared readers must not block each other.
// -------------------------------------------------------------------
//
// This test is a smoke contract for GAP-0753: given that snapshotUnderReadLock
// takes the *shared* reader lock (not the exclusive writer), two readers
// should enter the lock back-to-back regardless of how long the first reader
// holds the lock.  Today this already holds because the underlying lock is a
// shared rwlock — the test is belt-and-suspenders so a future switch to a
// mutex would be caught.

const ThreadACtx = struct {
    graph_name: []const u8,
    ready: *std.atomic.Value(u32),
    hold_ns: u64,
};

const ThreadBCtx = struct {
    graph_name: []const u8,
    ready: *std.atomic.Value(u32),
    start_ns: *u64,
    lock_acquired_ns: *u64,
};

fn threadAHoldReadLock(ctx: *ThreadACtx) void {
    const h = graph_store.acquireGraphReadLock(ctx.graph_name);
    ctx.ready.store(1, .release);
    sleepNs(ctx.hold_ns);
    graph_store.releaseGraphLock(h);
}

fn threadBAcquireReadLock(ctx: *ThreadBCtx) void {
    waitForFlag(ctx.ready);
    ctx.start_ns.* = monoNanos();
    const h = graph_store.acquireGraphReadLock(ctx.graph_name);
    ctx.lock_acquired_ns.* = monoNanos();
    graph_store.releaseGraphLock(h);
}

test "concurrent shared readers acquire the graph read lock in <1ms" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    const graph_name = "test_handler_lock_hold_scope_reads";
    store.createGraph(graph_name) catch |err| switch (err) {
        error.GraphAlreadyExists => {},
        else => return err,
    };

    var ready = std.atomic.Value(u32).init(0);
    var a_ctx = ThreadACtx{
        .graph_name = graph_name,
        .ready = &ready,
        .hold_ns = 30 * std.time.ns_per_ms,
    };

    var start_ns: u64 = 0;
    var acquired_ns: u64 = 0;
    var b_ctx = ThreadBCtx{
        .graph_name = graph_name,
        .ready = &ready,
        .start_ns = &start_ns,
        .lock_acquired_ns = &acquired_ns,
    };

    const t_a = try std.Thread.spawn(.{}, threadAHoldReadLock, .{&a_ctx});
    const t_b = try std.Thread.spawn(.{}, threadBAcquireReadLock, .{&b_ctx});

    t_a.join();
    t_b.join();

    const wait_ns = acquired_ns - start_ns;
    const wait_ms = @as(f64, @floatFromInt(wait_ns)) / 1_000_000.0;
    if (wait_ms >= 1.0) {
        std.debug.print(
            "thread B waited {d:.3} ms to acquire the shared read lock " ++
                "(expected < 1 ms). Shared readers should not serialize.\n",
            .{wait_ms},
        );
        return error.SharedReadersSerialized;
    }
}

// -------------------------------------------------------------------
// Test B — the handler's *lock-hold* scope on the read path is bounded
// by snapshot capture, NOT by the execute window.
// -------------------------------------------------------------------
//
// Setup: thread 1 acquires the WRITE lock (simulating a concurrent mutation)
// and holds it for `hold_ns`.  Thread 2 uses
// `graph_store.snapshotUnderReadLock` — the function this task adds — to
// take a QueryReadSession.  We measure how long thread 2's *lock* was held:
// the time from just before `snapshotUnderReadLock` was called until just
// after it returned.
//
// With the old handler path (acquireGraphReadLock → execute → release), the
// reader would wait for the writer to finish and then *also* hold the lock
// for the full execute window.  With `snapshotUnderReadLock`, the reader
// still waits for the writer, but once the writer releases the lock the
// reader's hold is bounded by the snapshot copy — a few ms on a small graph.
//
// The assertion compares the reader's *snapshot hold* (from call-start to
// return) to a generous 40 ms budget: it must cover the writer's hold
// (~30 ms) plus the snapshot clone (~5 ms) but NOT the simulated execute
// window (another 30 ms) that happens AFTER snapshotUnderReadLock returns.

const WriteCtx = struct {
    graph_name: []const u8,
    go: *std.atomic.Value(u32),
    hold_ns: u64,
    lock_acquired_ns: *u64,
    lock_released_ns: *u64,
};

const ReadCtx = struct {
    graph_name: []const u8,
    allocator: std.mem.Allocator,
    writer_engaged: *std.atomic.Value(u32),
    sim_execute_ns: u64,
    snapshot_hold_ns: *u64,
    post_snapshot_total_ns: *u64,
};

fn writerHoldsLock(ctx: *WriteCtx) void {
    const h = graph_store.acquireGraphWriteLock(ctx.graph_name);
    ctx.lock_acquired_ns.* = monoNanos();
    // Signal that the writer has the lock so the reader thread can proceed
    // toward snapshotUnderReadLock (which will block on this writer).
    ctx.go.store(1, .release);
    sleepNs(ctx.hold_ns);
    ctx.lock_released_ns.* = monoNanos();
    graph_store.releaseGraphLock(h);
}

fn readerSnapshotAndExecute(ctx: *ReadCtx) void {
    // Wait until the writer has actually engaged the write lock — otherwise
    // the reader might race past and never observe contention.
    waitForFlag(ctx.writer_engaged);

    const t_snapshot_start = monoNanos();
    var session = graph_store.snapshotUnderReadLock(ctx.allocator, ctx.graph_name) catch |err| {
        std.debug.print("snapshotUnderReadLock failed: {s}\n", .{@errorName(err)});
        return;
    };
    const t_snapshot_end = monoNanos();
    defer session.deinit();

    ctx.snapshot_hold_ns.* = t_snapshot_end - t_snapshot_start;

    // Simulate the "execute" phase outside the lock.  After GAP-0753 this
    // part runs without holding the graph read lock.
    sleepNs(ctx.sim_execute_ns);
    ctx.post_snapshot_total_ns.* = monoNanos() - t_snapshot_end;
}

test "snapshotUnderReadLock bounds lock hold to snapshot capture, not execute" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    const graph_name = "test_handler_lock_hold_scope_snapshot";
    store.createGraph(graph_name) catch |err| switch (err) {
        error.GraphAlreadyExists => {},
        else => return err,
    };

    // Seed a representative graph so the QueryReadSession clone does real
    // work (more than a handful of microseconds) — we want the budget
    // assertion to be meaningful.
    const labels = [_][]const u8{"Person"};
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        _ = try store.createNodeWithGraph(&labels, graph_name);
    }

    var go = std.atomic.Value(u32).init(0);
    var writer_acquired_ns: u64 = 0;
    var writer_released_ns: u64 = 0;
    var write_ctx = WriteCtx{
        .graph_name = graph_name,
        .go = &go,
        .hold_ns = 30 * std.time.ns_per_ms,
        .lock_acquired_ns = &writer_acquired_ns,
        .lock_released_ns = &writer_released_ns,
    };

    var snapshot_hold_ns: u64 = 0;
    var post_snapshot_ns: u64 = 0;
    var read_ctx = ReadCtx{
        .graph_name = graph_name,
        .allocator = allocator,
        .writer_engaged = &go,
        .sim_execute_ns = 30 * std.time.ns_per_ms,
        .snapshot_hold_ns = &snapshot_hold_ns,
        .post_snapshot_total_ns = &post_snapshot_ns,
    };

    const t_writer = try std.Thread.spawn(.{}, writerHoldsLock, .{&write_ctx});
    const t_reader = try std.Thread.spawn(.{}, readerSnapshotAndExecute, .{&read_ctx});

    t_writer.join();
    t_reader.join();

    // Budget: snapshotUnderReadLock's duration includes waiting for the
    // writer plus the snapshot clone (< 10 ms).  Measure the writer's actual
    // lock duration instead of assuming nanosleep returns exactly on time; the
    // pre-push shard runner can add scheduler jitter while still preserving the
    // contract that execute must not be covered by the lock hold.
    const hold_ms = @as(f64, @floatFromInt(snapshot_hold_ns)) / 1_000_000.0;
    const writer_hold_ns = writer_released_ns - writer_acquired_ns;
    const writer_hold_ms = @as(f64, @floatFromInt(writer_hold_ns)) / 1_000_000.0;
    const exec_ms = @as(f64, @floatFromInt(read_ctx.sim_execute_ns)) / 1_000_000.0;
    const budget_ms: f64 = writer_hold_ms + 10.0;
    if (hold_ms > budget_ms) {
        std.debug.print(
            "snapshotUnderReadLock held the graph read lock for {d:.3} ms " ++
                "(writer window: {d:.3} ms, simulated execute: {d:.3} ms, " ++
                "budget: {d:.3} ms). Expected the snapshot-capture phase to " ++
                "NOT cover the execute window.\n",
            .{ hold_ms, writer_hold_ms, exec_ms, budget_ms },
        );
        return error.LockHeldAcrossExecute;
    }
}
