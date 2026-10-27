// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! gap0900-read-write-deadlock: deterministic regression for the three-actor
//! lock-ordering deadlock between the periodic HMAC verify loop, the
//! persistence-loop checkpoint, and the bulk-ingest workers.
//!
//! The cycle (diagnosed via gdb,
//! docs/performance/2026-06-19-bulk-merge-per-op-decay/deadlock-stacks.txt):
//!
//!   1. AuthGraphManager.periodicVerifyLoop wants the GLOBAL `g_store_rwlock`
//!      EXCLUSIVE.  The OLD code used the blocking `acquireStoreWriteLock`,
//!      which registers a PENDING writer in Io.RwLock (it `Add`s the writer
//!      count BEFORE parking).  A pending writer makes `lockSharedUncancelable`
//!      refuse every NEW shared acquire (writer-fair) until the writer wins.
//!
//!   2. The persistence-loop checkpoint holds `g_store_rwlock` SHARED while it
//!      takes a PER-GRAPH EXCLUSIVE lock (checkpointAllEx → mg.rwlock).
//!      So: holds g_store(shared) → wants per-graph(exclusive).
//!
//!   3. An ingest worker holds a PER-GRAPH SHARED lock and then wants
//!      `g_store_rwlock` SHARED.  So: holds per-graph(shared) → wants
//!      g_store(shared).
//!
//!   Cycle: (2) holds g_store-shared and is blocked wanting per-graph-exclusive
//!   (held by (3)).  (1) then becomes a PENDING g_store writer.  (3) now tries
//!   to take g_store SHARED but the pending writer (1) starves it (writer-fair)
//!   → (3) can't release per-graph → (2) never gets per-graph-exclusive →
//!   (2) holds g_store-shared forever → (1) never acquires g_store-exclusive.
//!   Full freeze.
//!
//! This test STAGES that exact interleaving deterministically with barriers,
//! driving the REAL `AuthGraphManager.runVerifyRound` (the factored-out body of
//! `periodicVerifyLoop`) against a REAL per-graph `mg.rwlock` and the REAL
//! global `g_store_rwlock`.
//!
//! BEFORE the fix (runVerifyRound used blocking `acquireStoreWriteLock`): the
//! staged interleaving wedges all three threads — `auth_t.join()` never returns
//! and the test process hangs until the CI timeout kills it (FAIL).  To keep
//! the failure observable rather than an infinite hang, a watchdog thread aborts
//! with a clear message after a bounded wait.
//!
//! AFTER the fix (runVerifyRound uses `acquireStoreWriteLockCancelable`, which
//! spins on `tryLock` and never registers a pending writer): the auth round
//! cannot starve the ingest g_store-SHARED acquire, the ingest worker releases
//! its per-graph lock, the checkpoint completes, every thread finishes, and the
//! test PASSES.

// CANARY: REQ=REQ-AUTH-HMAC-PERIODIC-DEADLOCK-001; FEATURE="PeriodicHmacVerification"; ASPECT=ReadWriteDeadlock; STATUS=TESTED; TEST=tests/test_auth_verify_checkpoint_deadlock.zig; OWNER=security; UPDATED=2026-06-19

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;
const auth_graph_manager_mod = @import("auth_graph_manager");
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;

const HMAC_KEY = [_]u8{0x5c} ** 32;

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
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ns), .awake) catch {};
}

fn ioGet() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn waitFlag(flag: *std.atomic.Value(u32)) void {
    while (flag.load(.acquire) == 0) sleepNs(200 * std.time.ns_per_us);
}

const Stage = struct {
    mgr: *AuthGraphManager,
    mg: *adapter_mod.ManagedGraph,

    // Barrier flags ordering the staged interleaving.
    ingest_holds_pergraph: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    ckpt_holds_gstore: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    auth_started_acquire: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Completion flags — each set when its actor fully finishes its critical
    // section. The test asserts all three complete within the watchdog bound.
    auth_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    ckpt_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    ingest_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

/// Actor 3 — ingest worker. Takes per-graph SHARED and holds it until the
/// checkpoint is blocked and the auth writer has begun its acquire, then tries
/// for g_store SHARED (the deadlock-prone acquire).
fn ingestWorker(s: *Stage) void {
    const i = ioGet();
    s.mg.rwlock.lockSharedUncancelable(i); // per-graph SHARED (held)
    s.ingest_holds_pergraph.store(1, .release);

    // Wait until the checkpoint is holding g_store SHARED (and thus blocked
    // wanting our per-graph EXCLUSIVE) and the auth writer has started its
    // g_store acquire — this is the moment the cycle would close.
    waitFlag(&s.ckpt_holds_gstore);
    waitFlag(&s.auth_started_acquire);
    sleepNs(50 * std.time.ns_per_ms); // let auth become a pending writer (OLD path)

    graph_store.acquireStoreLock(); // want g_store SHARED — starved pre-fix
    graph_store.releaseStoreLock();
    s.mg.rwlock.unlockShared(i); // release per-graph so checkpoint can proceed
    s.ingest_done.store(1, .release);
}

/// Actor 2 — persistence checkpoint. Holds g_store SHARED, then wants per-graph
/// EXCLUSIVE (blocked until ingest releases per-graph SHARED).
fn checkpointActor(s: *Stage) void {
    const i = ioGet();
    waitFlag(&s.ingest_holds_pergraph);
    graph_store.acquireStoreLock(); // g_store SHARED (held across per-graph wait)
    s.ckpt_holds_gstore.store(1, .release);
    s.mg.rwlock.lockUncancelable(i); // per-graph EXCLUSIVE — waits for ingest
    s.mg.rwlock.unlock(i);
    graph_store.releaseStoreLock();
    s.ckpt_done.store(1, .release);
}

/// Actor 1 — AuthGraphManager.periodicVerifyLoop, one real round.
fn authWriter(s: *Stage) void {
    waitFlag(&s.ckpt_holds_gstore); // ensure checkpoint already holds g_store SHARED
    s.auth_started_acquire.store(1, .release);
    s.mgr.runVerifyRound(); // wants g_store EXCLUSIVE
    s.auth_done.store(1, .release);
}

test "auth verify + checkpoint + ingest do not deadlock (gap0900-read-write-deadlock)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    var adapter = try adapter_mod.StorageAdapter.init(allocator, data_dir, .{
        .data_dir = data_dir,
        .encryption_key = null,
    });
    defer adapter.deinit();
    const mg = try adapter.getOrCreateGraph("g_deadlock");

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();
    _ = try mgr.createUser(&HMAC_KEY, "deadlockuser", "d@x", "fakehash", false);
    try mgr.verifyChain(&HMAC_KEY);
    mgr.hmac_key = HMAC_KEY; // runVerifyRound reads self.hmac_key

    var s = Stage{ .mgr = &mgr, .mg = mg };

    var ingest_t = try std.Thread.spawn(.{}, ingestWorker, .{&s});
    var ckpt_t = try std.Thread.spawn(.{}, checkpointActor, .{&s});
    var auth_t = try std.Thread.spawn(.{}, authWriter, .{&s});

    // Watchdog: if the staged cycle wedges (pre-fix), the three actors never
    // complete. Abort with a clear message so the failure is a fast, legible
    // FAIL rather than an opaque infinite hang at join().
    const deadline = monoNanos() + 20 * std.time.ns_per_s;
    while (monoNanos() < deadline) {
        if (s.auth_done.load(.acquire) == 1 and
            s.ckpt_done.load(.acquire) == 1 and
            s.ingest_done.load(.acquire) == 1)
        {
            break;
        }
        sleepNs(5 * std.time.ns_per_ms);
    }

    const all_done = s.auth_done.load(.acquire) == 1 and
        s.ckpt_done.load(.acquire) == 1 and
        s.ingest_done.load(.acquire) == 1;

    if (!all_done) {
        std.debug.print(
            "DEADLOCK: staged auth-verify ⨯ checkpoint ⨯ ingest cycle did not resolve within 20s " ++
                "(auth_done={d} ckpt_done={d} ingest_done={d})\n",
            .{
                s.auth_done.load(.acquire),
                s.ckpt_done.load(.acquire),
                s.ingest_done.load(.acquire),
            },
        );
        // Threads are wedged; we cannot join them. Fail hard and let the test
        // runner tear down the process.
        std.debug.print("FAIL: deadlock detected — aborting wedged test process\n", .{});
        std.process.exit(1);
    }

    auth_t.join();
    ckpt_t.join();
    ingest_t.join();

    try std.testing.expect(all_done);
}
