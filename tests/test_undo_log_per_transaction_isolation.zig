// Regression tests for R1 — process-global undo log race.
//
// Triage: parallel Go-client ingestion (16 workers, chunks of 38 statements)
// hangs the Geode server; on shutdown we see:
//     thread-pool deinit timed out after 30000ms with 1 active tasks and 0 queued
//
// Root cause R1 (CRITICAL correctness): `global_undo_log` in
// src/txn_undo_log.zig:651 is a *process-global* singleton with no per-
// transaction isolation and no mutex around its append path.
//
//   - UndoLog.begin()   (src/txn_undo_log.zig:266)  calls `self.clear()`,
//                       wiping any *other* concurrent transaction's
//                       not-yet-committed entries.
//   - UndoLog.entries   (src/txn_undo_log.zig:160)  is a plain
//                       `ArrayListUnmanaged` — concurrent appends from two
//                       threads race on the same backing slice/length
//                       fields.
//   - getGlobalUndoLog() (src/txn_undo_log.zig:653) returns the SAME
//                       pointer to every caller.
//
// When two connection handlers hit BEGIN/CREATE ... in parallel, the second
// BEGIN silently erases the first transaction's undo entries, so a later
// ROLLBACK either replays an empty log (data corruption) or crashes on a
// half-freed entry.  That's the observable hang in the triage report.
//
// These tests must FAIL on the current code.  They are written against the
// desired contract:
//
//   (T1) begin() from a second thread must NOT wipe undo entries that a
//        first thread already recorded inside its own transaction.
//   (T2) concurrent appends to undo entries must not corrupt the list
//        (length monotonicity per tx, no torn writes, no lost entries).
//
// The fix is expected to land a per-handle UndoLog (or equivalent per-
// transaction scoping) so that distinct transactions have independent
// entries.  Once that ships, both tests pass.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const txn_undo_log = geode.txn_undo_log;

// Zig 0.16 compat — see tests/test_handler_lock_hold_scope.zig:34-56.
fn sleepNs(ns: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ns), .awake) catch {};
}

fn waitForFlag(flag: *std.atomic.Value(u32)) void {
    while (flag.load(.acquire) == 0) std.atomic.spinLoopHint();
}

// -------------------------------------------------------------------
// T1 — A second transaction's begin() must not wipe the first's entries.
// -------------------------------------------------------------------
//
// Thread A:  begin()  → logCreateNode(A)  → logCreateNode(A)  → (stall)
// Thread B:  begin()                          (runs during A's stall)
// Thread A:  asserts len >= 2  (B's begin wiped them → 0, test fails)
//
// Today `begin()` calls `clear()` on the shared global, so by the time A
// inspects `entries.items.len` it is 0.  After R1 is fixed (per-txn undo
// log), B's begin() is scoped to its own object and cannot touch A's.
//
// Regression: R1 — process-global singleton with no per-tx isolation.

const IsolationCtxA = struct {
    allocator: std.mem.Allocator,
    start_b: *std.atomic.Value(u32),
    b_began: *std.atomic.Value(u32),
    entries_after_b_begin: *usize,
};

const IsolationCtxB = struct {
    allocator: std.mem.Allocator,
    start_b: *std.atomic.Value(u32),
    b_began: *std.atomic.Value(u32),
};

fn threadARecordAndStall(ctx: *IsolationCtxA) void {
    const undo = txn_undo_log.getGlobalUndoLog(ctx.allocator);
    undo.begin();
    undo.logCreateNode(10001, "default") catch |err| {
        std.debug.print("A logCreateNode #1 failed: {s}\n", .{@errorName(err)});
        return;
    };
    undo.logCreateNode(10002, "default") catch |err| {
        std.debug.print("A logCreateNode #2 failed: {s}\n", .{@errorName(err)});
        return;
    };

    // Hand control to B: tell B it may begin() its own transaction, then
    // wait until B signals that its begin() has returned.
    ctx.start_b.store(1, .release);
    waitForFlag(ctx.b_began);

    // Read our own entry count.  The contract we are pinning: "A's
    // transaction entries survive a concurrent BEGIN from another
    // transaction."  Today this is 0 because B's begin() called clear()
    // on the shared global undo log.
    const observed = undo.entries.items.len;
    ctx.entries_after_b_begin.* = observed;

    // Roll this back so the global state isn't poisoned for the next test.
    // Rollback may no-op if entries were already cleared — that's fine,
    // we only care about the count captured above.
    undo.active = false;
    undo.clear();
}

fn threadBBegin(ctx: *IsolationCtxB) void {
    waitForFlag(ctx.start_b);
    const undo = txn_undo_log.getGlobalUndoLog(ctx.allocator);
    undo.begin();
    ctx.b_began.store(1, .release);
    // Leave B's (empty) transaction as-is.  Thread A does the final clear.
}

test "undo log: concurrent begin() does not wipe other transaction's entries (R1)" {
    const allocator = testing.allocator;

    // Make sure we start clean — other tests in the binary may have left
    // the global undo log dirty.
    {
        const undo = txn_undo_log.getGlobalUndoLog(allocator);
        undo.active = false;
        undo.clear();
    }

    var start_b = std.atomic.Value(u32).init(0);
    var b_began = std.atomic.Value(u32).init(0);
    var entries_after_b_begin: usize = std.math.maxInt(usize);

    var a_ctx = IsolationCtxA{
        .allocator = allocator,
        .start_b = &start_b,
        .b_began = &b_began,
        .entries_after_b_begin = &entries_after_b_begin,
    };
    var b_ctx = IsolationCtxB{
        .allocator = allocator,
        .start_b = &start_b,
        .b_began = &b_began,
    };

    const t_a = try std.Thread.spawn(.{}, threadARecordAndStall, .{&a_ctx});
    const t_b = try std.Thread.spawn(.{}, threadBBegin, .{&b_ctx});
    t_a.join();
    t_b.join();

    // Per-transaction isolation: A recorded exactly 2 entries before B
    // started its transaction.  A should still see them.
    if (entries_after_b_begin != 2) {
        std.debug.print(
            "Thread A observed {d} undo entries after Thread B's BEGIN — " ++
                "expected 2.  Global undo log is shared across transactions: " ++
                "B's begin() called clear() on A's entries.  This is R1 in " ++
                "src/txn_undo_log.zig:266-271 / 651-658.\n",
            .{entries_after_b_begin},
        );
        return error.GlobalUndoLogSharedAcrossTransactions;
    }
}

// -------------------------------------------------------------------
// T2 — Concurrent appends to the global undo log must not lose entries.
// -------------------------------------------------------------------
//
// N threads each append `appends_per_thread` entries to the process-global
// undo log via logCreateNode.  Today `UndoLog.entries` is a plain
// `ArrayListUnmanaged` with no mutex around `.append()`, so concurrent
// appends race on the length / backing-slice fields — entries are lost or
// writes tear.  We assert the obvious invariant: total entries after the
// join == threads * appends_per_thread.
//
// When this test is run under ThreadSanitizer or MSan it will also flag
// the race directly.  Without a sanitizer, the loss-of-entries assertion
// is the load-bearing check.
//
// NOTE: `logCreateNode` allocates (it dupes `graph_name`) on the shared
// allocator, so this also covers the allocator-contention aspect of R1.

const appends_per_thread: usize = 200;
const concurrent_threads: usize = 8;

const StressCtx = struct {
    allocator: std.mem.Allocator,
    go: *std.atomic.Value(u32),
};

fn stressAppender(ctx: *StressCtx) void {
    waitForFlag(ctx.go);
    const undo = txn_undo_log.getGlobalUndoLog(ctx.allocator);
    // SONNY-2799: a change is recorded only inside a transaction, so each
    // thread is one (it relied on another thread's BEGIN setting the log's
    // global `active` flag, which recorded every thread's changes under
    // transaction 0).
    undo.begin();
    var i: usize = 0;
    while (i < appends_per_thread) : (i += 1) {
        undo.logCreateNode(@intCast(i + 1), "default") catch |err| {
            // A partial failure (OutOfMemory from a torn ArrayList grow,
            // for instance) is itself evidence of the bug — count it as
            // a lost entry by returning early.
            std.debug.print("stressAppender failed at i={d}: {s}\n", .{ i, @errorName(err) });
            return;
        };
    }
}

test "undo log: concurrent appends do not lose entries or corrupt the list (R1)" {
    const allocator = testing.allocator;

    // Clean up residue from T1 or any other test.
    {
        const undo = txn_undo_log.getGlobalUndoLog(allocator);
        undo.active = false;
        undo.clear();
        undo.begin();
    }

    var go = std.atomic.Value(u32).init(0);
    var ctx = StressCtx{ .allocator = allocator, .go = &go };

    var threads: [concurrent_threads]std.Thread = undefined;
    var t: usize = 0;
    while (t < concurrent_threads) : (t += 1) {
        threads[t] = try std.Thread.spawn(.{}, stressAppender, .{&ctx});
    }

    // Release all threads simultaneously to maximize race exposure.
    go.store(1, .release);

    for (threads) |th| th.join();

    const undo = txn_undo_log.getGlobalUndoLog(allocator);
    const expected = concurrent_threads * appends_per_thread;
    const observed = undo.entries.items.len;

    // Leave a clean state for anything that runs after this test.
    undo.active = false;
    undo.clear();

    if (observed != expected) {
        std.debug.print(
            "Concurrent appends to the global undo log lost entries: " ++
                "expected {d}, got {d}. Race on ArrayListUnmanaged at " ++
                "src/txn_undo_log.zig:160 (see R1 in the triage).\n",
            .{ expected, observed },
        );
        return error.UndoLogLostConcurrentAppends;
    }
}
