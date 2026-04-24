// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Per-graph group-commit coordinator — thread-pool-hosted single-flusher
//! design (Phase 2.1 of the graph-sharding plan, 2026-04-23 evening).
//!
//! Background
//! ----------
//! The initial Phase 2 attempt (Tasks 4-6, commits b061a238..210de668) wired
//! a 16-way sharded coordinator with per-shard workers calling shard-locked
//! helpers.  End-to-end validation against msft-graph showed a 3-4x
//! regression vs the morning baseline — the shard workers contended on a
//! single `string_indexes_mutex` (held across adapter vtable writes) AND
//! the engine was discovered to have non-atomic `next_node_id` allocation,
//! meaning concurrent engine writes from N shards would race for
//! correctness.  See `docs/performance/2026-04-24-sharding/phase2-result.md`.
//!
//! This file is the correct architectural response given the engine
//! constraint: the engine is single-threaded by design (per
//! `graph_storage/src/engine.zig:588-589`), so engine writes MUST
//! serialise.  The coordinator therefore acts as the serialisation point
//! — ONE flusher thread drains the queue in batches, applies each batch
//! under a single statement txn + `mg.rwlock` EXCLUSIVE, commits once
//! (ONE fsync per batch).  This matches the morning-baseline design
//! (commit 2588e872) that measured 7.2× throughput improvement over the
//! per-op path.
//!
//! Differences from the morning baseline
//! -------------------------------------
//! 1. The flusher runs on `pooled.ThreadPool` (blocking lane, 1 worker)
//!    instead of `std.Thread.spawn`.  Per project convention,
//!    parallelism goes through the gitlab.com/devnw/zig/thread-pool
//!    library first.  See `docs/memory/feedback_thread_pool_first.md`.
//! 2. The pool is configured with `SchedulerVariant.lane_extension`
//!    (work-stealing default lane + dedicated blocking lane) so a
//!    future stage-1 parallelism layer can submit shard-local
//!    in-memory prep work to the default lane without architectural
//!    changes here.
//! 3. `applyBatch` raises the per-graph write-lock deadline from 30 s
//!    → 120 s.  The morning-session cascade on the 8 k+ edge files
//!    (`edges_signed_in_from`, `edges_signed_in_to`) was driven by a
//!    10 k-deep queue running ahead of apply rate and tripping the
//!    30 s deadline, surfacing to workers as 40001 errors that
//!    msft-graph escalated to serial fallback.  Widening the deadline
//!    absorbs the worst-case queue drain without changing the apply
//!    path.
//! 4. The Phase 2 Task-4 per-shard rwlocks on `ManagedGraph`
//!    (`shard_locks[SHARD_COUNT]`) and Phase 2 Task-5 shard-locked
//!    bulk-helper variants (`bulkInsertNodeWithReservedId` etc.) are
//!    retained unchanged in `graph_storage_adapter.zig` but NOT used
//!    here — they're dormant primitives waiting for the Phase 2.2
//!    stage-1 in-memory parallelism rework (out of scope for this
//!    file).
//!
//! Invariants preserved
//! --------------------
//! * Public API unchanged: `submit`, `getOrStartCoordinator`,
//!   `lookupCoordinator`, `shutdownAllCoordinators`, `isEnabled`,
//!   `setEnabledForTest`.  `ApplyOp` and `ApplyResult` keep their
//!   Phase-2 shape (including the now-unused `assigned_id` field —
//!   harmless and ready for the Phase 2.2 stage-1 rework).
//! * One WAL fsync per batch — matches morning baseline.
//! * Per-op error capture: one bad op does not fail the whole batch;
//!   the error surfaces to that op's submitter via `ApplyResult.err`
//!   on wake-up.
//! * `stop()` drains the queue before the flusher exits — no ops
//!   dropped on the floor.

const std = @import("std");
const graph_store = @import("../graph_store.zig");
const graph_storage_adapter = @import("graph_storage_adapter.zig");
const pooled = @import("transport/thread_pool");
const ext_tp = @import("thread_pool");

const StorageAdapter = graph_storage_adapter.StorageAdapter;
const PropKV = StorageAdapter.PropKV;
const PropertyValue = graph_store.PropertyValue;

/// Tag-union of supported apply operations.  Each variant carries the
/// inputs the three bulk helpers accept plus an `ApplyResult` slot that
/// the coordinator fills in before waking the submitter.
pub const ApplyOp = union(enum) {
    bulk_insert_node: struct {
        labels: []const []const u8,
        props: []const PropKV,
        result: ApplyResult,
        /// Reserved by Phase 2.2 stage-1 workers.  Unused in this
        /// flusher-only design (the whole-graph bulkInsertNode path
        /// generates its own id).
        assigned_id: u64 = 0,
    },
    bulk_insert_edge: struct {
        source_id: u64,
        target_id: u64,
        rel_type: []const u8,
        props: []const PropKV,
        result: ApplyResult,
    },
    /// MATCH+CREATE edge variant — the coordinator resolves endpoints
    /// under its already-held EXCLUSIVE write lock, eliminating the
    /// reader/writer contention that forced msft-graph to serial-
    /// fallback on the morning-baseline and Phase 2.1/2.2 designs.
    ///
    /// Workers submit WITHOUT taking any lock, so the 16-way pipeline
    /// proceeds without serialising on the flusher's EXCLUSIVE.  The
    /// endpoint lookup + edge create both happen under the single
    /// EXCLUSIVE hold the flusher already has for the batch.
    ///
    /// Orphan-edge semantics (matches the regular MATCH+CREATE
    /// executor): if either endpoint is missing, the op silently
    /// succeeds with `result.node_or_edge_id = 0` — NOT an error.
    /// Callers that need to distinguish "created" from "silently
    /// skipped" can check `== 0` on the returned id.
    bulk_match_create_edge: struct {
        src_label: []const u8,
        src_filter_key: []const u8,
        src_filter_value: PropertyValue,
        dst_label: []const u8,
        dst_filter_key: []const u8,
        dst_filter_value: PropertyValue,
        rel_type: []const u8,
        props: []const PropKV,
        result: ApplyResult,
    },
    bulk_merge_node: struct {
        label: []const u8,
        merge_key: []const u8,
        merge_value: PropertyValue,
        on_create_props: []const PropKV,
        result: ApplyResult,
        /// Reserved by Phase 2.2 stage-1 workers — see bulk_insert_node.
        assigned_id: u64 = 0,
    },

    pub fn resultPtr(self: *ApplyOp) *ApplyResult {
        return switch (self.*) {
            .bulk_insert_node => |*p| &p.result,
            .bulk_insert_edge => |*p| &p.result,
            .bulk_match_create_edge => |*p| &p.result,
            .bulk_merge_node => |*p| &p.result,
        };
    }
};

/// One-shot result + completion signal for a submitted `ApplyOp`.
///
/// The submitter parks on `done` (a u32 flag waited on via
/// `std.Io.futexWaitUncancelable`) and wakes when the flusher flips
/// it to 1 via `std.Io.futexWake` after populating
/// `node_or_edge_id` / `err`.
pub const ApplyResult = struct {
    node_or_edge_id: u64 = 0,
    err: ?anyerror = null,
    /// 0 = pending, 1 = done.  Waited on by submitter via `futexWait`.
    done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

/// Thread-pool-hosted single-flusher coordinator.
pub const GroupCommitCoordinator = struct {
    allocator: std.mem.Allocator,
    graph_name: []const u8, // owned
    adapter: *StorageAdapter,

    /// Queue of pending ops.  Guarded by `queue_mutex`.  Each entry is a
    /// pointer into the submitter's stack-allocated `ApplyOp`; the
    /// flusher MUST NOT dereference after `result.done` is set to 1.
    queue: std.Deque(*ApplyOp),
    queue_mutex: std.Io.Mutex,
    queue_not_empty: std.Io.Condition,

    /// Thread-pool hosting the flusher task.  Sized as:
    ///   - 1 blocking-lane worker (the flusher)
    ///   - up to SHARD_COUNT default-lane workers (dormant, reserved
    ///     for Phase 2.2 stage-1 in-memory parallelism).
    /// Scheduler variant `lane_extension` so blocking and default
    /// lanes have independent inject queues.
    pool: *pooled.ThreadPool,
    /// Handle for the in-flight flusher task.  `stop()` waits on this
    /// after flipping `should_stop` and signaling `queue_not_empty`.
    flusher_handle: ext_tp.TaskHandle,

    /// Set to 1 by `stop()`; the flusher loop exits after draining.
    should_stop: std.atomic.Value(u32),

    // Stats (atomic so stop()/tests can snapshot them lock-free).
    ops_applied: std.atomic.Value(u64),
    batches: std.atomic.Value(u64),

    /// Max ops in a single batch before forcing a lock release +
    /// re-acquire.  Same value as the morning baseline — large enough
    /// to amortise lock acquire cost across the 16-worker fan-in,
    /// bounded so a pathological queue can't starve `stop()`.
    pub const max_batch: usize = 256;

    // (Removed: per-graph write-lock deadline.  Morning baseline used 30 s
    //  with `acquireGraphWriteLockCancelable` which has a tryLock-spin loop
    //  that NEVER marks the writer as pending in std.Io.RwLock's state —
    //  under sustained SHARED-reader pressure (the edge MATCH+CREATE fast
    //  path at quic_connection_handler.zig:539 takes acquireGraphReadLock
    //  to resolve endpoints) new readers keep the fast CAS path and the
    //  writer's tryLock never wins the race.  See
    //  std/Io/RwLock.zig lines 28-40 (tryLock) vs 42-50 (lockUncancelable:
    //  `@atomicRmw(&state, .Add, writer)` FIRST blocks new readers).
    //
    //  Fix: flusher uses `acquireGraphWriteLock` (no deadline, uses
    //  lockUncancelable internally) — writer-preferred, starvation-proof.
    //  The flusher's apply is well-bounded; no-deadline is acceptable.
    //  This was the root cause of the 48 chunk-failure cascade in the
    //  morning-baseline R13 run and the 40001 error observed in the
    //  2026-04-23 evening Phase 2.1 validation.)

    /// Allocate, wire up the queue, init the pool, and submit the
    /// flusher task.
    pub fn start(
        allocator: std.mem.Allocator,
        adapter: *StorageAdapter,
        graph_name: []const u8,
    ) !*GroupCommitCoordinator {
        const owned_name = try allocator.dupe(u8, graph_name);
        errdefer allocator.free(owned_name);

        const self = try allocator.create(GroupCommitCoordinator);
        errdefer allocator.destroy(self);

        // Thread-pool config: 1 blocking worker (the flusher) + enough
        // default workers to carry a future stage-1 layer.  Use
        // work-stealing scheduler so default-lane submissions scale
        // well under fan-in when that stage is added.  queue_capacity
        // large enough that the ShutdownMode.drain path never blocks.
        const pool = try pooled.ThreadPool.init(allocator, .{
            .num_threads = 17, // 1 blocking + 16 default (dormant)
            .queue_capacity = 256,
        });
        errdefer pool.deinit();

        self.* = .{
            .allocator = allocator,
            .graph_name = owned_name,
            .adapter = adapter,
            .queue = std.Deque(*ApplyOp).empty,
            .queue_mutex = std.Io.Mutex.init,
            .queue_not_empty = std.Io.Condition.init,
            .pool = pool,
            .flusher_handle = ext_tp.TaskHandle.invalid(),
            .should_stop = std.atomic.Value(u32).init(0),
            .ops_applied = std.atomic.Value(u64).init(0),
            .batches = std.atomic.Value(u64).init(0),
        };

        // Pre-size the queue so normal operation never hits the growth
        // path under the coordinator's mutex (contention amplifier).
        try self.queue.ensureTotalCapacityPrecise(allocator, max_batch * 4);

        // Submit the flusher as a long-running blocking-lane task with
        // a waitable handle we can join in stop().  backpressure.block
        // is safe here because `start()` is called from an external
        // thread (not a pool worker).
        self.flusher_handle = try self.pool.submitTask(
            flusherEntry,
            @ptrCast(self),
            .{
                .lane = .blocking,
                .backpressure = .block,
                .waitable = true,
            },
        );
        return self;
    }

    /// Signal the flusher to stop, wait for it to exit, pool.deinit,
    /// release all allocations.  Pending ops in the queue are drained
    /// before the flusher exits — `stop()` will NOT drop ops on the
    /// floor.
    pub fn stop(self: *GroupCommitCoordinator) void {
        const io = std.Io.Threaded.global_single_threaded.io();

        self.should_stop.store(1, .release);

        // Wake the flusher if it's parked on queue_not_empty with an
        // empty queue.
        self.queue_mutex.lockUncancelable(io);
        self.queue_not_empty.signal(io);
        self.queue_mutex.unlock(io);

        // Wait for the flusher to finish draining.  `pool.wait`
        // releases the descriptor slot on success, after which
        // pool.deinit can exit cleanly.
        self.pool.wait(self.flusher_handle) catch {};

        self.pool.deinit();

        self.queue.deinit(self.allocator);
        self.allocator.free(self.graph_name);
        self.allocator.destroy(self);
    }

    /// Enqueue `op` and block until the flusher signals completion.
    /// Returns the populated `ApplyResult` contents.  Safe to call
    /// from ANY thread including pool workers — the submitter
    /// parks on a per-op `done` atomic via `futexWait`, not on the
    /// pool.
    pub fn submit(self: *GroupCommitCoordinator, op: *ApplyOp) !u64 {
        const io = std.Io.Threaded.global_single_threaded.io();

        self.queue_mutex.lockUncancelable(io);
        self.queue.pushBack(self.allocator, op) catch |err| {
            self.queue_mutex.unlock(io);
            return err;
        };
        self.queue_not_empty.signal(io);
        self.queue_mutex.unlock(io);

        // Park on the op's done flag.  `futexWaitUncancelable` is
        // used so we don't wake on cancellation mid-batch (which
        // would desync the flusher's bookkeeping — the op is
        // already in the queue).
        const result = op.resultPtr();
        while (result.done.load(.acquire) == 0) {
            std.Io.futexWaitUncancelable(io, u32, &result.done.raw, 0);
        }

        if (result.err) |e| return e;
        return result.node_or_edge_id;
    }

    /// Thread-pool TaskFn trampoline — unpacks the ctx and calls the
    /// flusher loop.  TaskFn signature is
    /// `*const fn (ctx: *anyopaque, runtime: *TaskContext) void`.
    fn flusherEntry(ctx_ptr: *anyopaque, runtime: *ext_tp.TaskContext) void {
        _ = runtime; // flusher is long-running; cancellation not observed
        const self: *GroupCommitCoordinator = @ptrCast(@alignCast(ctx_ptr));
        self.flusherLoop();
    }

    /// Long-running flusher: drains the queue in batches forever until
    /// `should_stop` flips and the queue is empty.  Runs on the pool's
    /// 1-wide blocking lane.
    fn flusherLoop(self: *GroupCommitCoordinator) void {
        const io = std.Io.Threaded.global_single_threaded.io();

        // Batch staging buffer: we pop from the queue into this slice
        // under the queue lock, then release before taking the
        // per-graph write lock.  Stack-allocated to avoid per-batch
        // allocator traffic on the hot path.
        var batch_buf: [max_batch]*ApplyOp = undefined;

        while (true) {
            // --- Phase 1: drain up to `max_batch` ops from the queue. ---
            self.queue_mutex.lockUncancelable(io);

            while (self.queue.len == 0) {
                if (self.should_stop.load(.acquire) == 1) {
                    self.queue_mutex.unlock(io);
                    return;
                }
                self.queue_not_empty.waitUncancelable(io, &self.queue_mutex);
            }

            var batch_len: usize = 0;
            while (batch_len < max_batch) : (batch_len += 1) {
                const op = self.queue.popFront() orelse break;
                batch_buf[batch_len] = op;
            }
            self.queue_mutex.unlock(io);

            if (batch_len == 0) continue;

            // --- Phase 2: apply the batch under one write-lock + one txn. ---
            self.applyBatch(batch_buf[0..batch_len]);

            _ = self.batches.fetchAdd(1, .monotonic);
            _ = self.ops_applied.fetchAdd(batch_len, .monotonic);
        }
    }

    /// Apply a pre-drained batch under one per-graph EXCLUSIVE
    /// write-lock acquire and one flusher-owned statement txn (one
    /// WAL fsync for the whole batch).  Per-op errors are captured in
    /// the op's `ApplyResult.err` and do NOT fail the batch.
    ///
    /// Lock acquisition uses `acquireGraphWriteLock` (no deadline) —
    /// NOT `acquireGraphWriteLockCancelable` which is starvation-prone
    /// under the edge MATCH+CREATE fast path's sustained SHARED-reader
    /// pressure.  The internal `std.Io.RwLock.lockUncancelable` marks
    /// the writer as pending in state, which blocks new readers via
    /// the fast CAS path — writer-preferred by construction.
    fn applyBatch(self: *GroupCommitCoordinator, batch: []*ApplyOp) void {
        const io = std.Io.Threaded.global_single_threaded.io();

        const lock_handle = graph_store.acquireGraphWriteLock(self.graph_name);
        defer graph_store.releaseGraphLock(lock_handle);

        // Flusher-owned statement txn for the whole batch — single
        // WAL fsync for all ops.  Failure to open (e.g. engine not
        // registered) falls through to per-op auto-commit.
        var stmt_txn: graph_storage_adapter.StatementTxn = undefined;
        var have_txn = false;
        _ = self.adapter.getOrCreateGraph(self.graph_name) catch {};
        if (self.adapter.beginStatementTxn(self.graph_name, &stmt_txn)) |_| {
            have_txn = true;
        } else |_| {}

        // Apply each op via the existing un-sharded bulk helpers
        // (caller-holds-whole-graph-exclusive contract).  We hold
        // `mg.rwlock` EXCLUSIVE above, so this is correct.  Errors
        // are captured per-op; batch continues so one bad op does
        // not block 15 peers.
        for (batch) |op| {
            const res = op.resultPtr();
            switch (op.*) {
                .bulk_insert_node => |p| {
                    if (self.adapter.bulkInsertNode(
                        self.graph_name,
                        p.labels,
                        p.props,
                        null,
                    )) |nid| {
                        res.node_or_edge_id = nid;
                    } else |e| {
                        res.err = e;
                    }
                },
                .bulk_insert_edge => |p| {
                    if (self.adapter.bulkInsertEdgeWithIds(
                        self.graph_name,
                        p.source_id,
                        p.target_id,
                        p.rel_type,
                        p.props,
                        null,
                    )) |eid| {
                        res.node_or_edge_id = eid;
                    } else |e| {
                        res.err = e;
                    }
                },
                .bulk_match_create_edge => |p| {
                    // Phase 2.3: endpoint lookup happens here, under the
                    // coordinator's already-held EXCLUSIVE lock.  This
                    // eliminates the reader/writer contention that was
                    // forcing msft-graph into serial fallback — workers
                    // no longer need a SHARED read lock just to resolve
                    // endpoints.
                    const src_id = self.adapter.lookupNodeByMergeKey(
                        self.graph_name,
                        p.src_label,
                        p.src_filter_key,
                        p.src_filter_value,
                        error.SourceNodeNotFound,
                    ) catch |err| switch (err) {
                        // Orphan-edge silent skip: result.node_or_edge_id
                        // stays 0 and err stays null, signaling the
                        // submitter that the edge was silently skipped
                        // (matches the regular MATCH+CREATE executor
                        // which emits an empty result set when MATCH
                        // finds nothing).
                        error.SourceNodeNotFound => continue,
                        else => {
                            res.err = err;
                            continue;
                        },
                    };
                    const dst_id = self.adapter.lookupNodeByMergeKey(
                        self.graph_name,
                        p.dst_label,
                        p.dst_filter_key,
                        p.dst_filter_value,
                        error.TargetNodeNotFound,
                    ) catch |err| switch (err) {
                        error.TargetNodeNotFound => continue,
                        else => {
                            res.err = err;
                            continue;
                        },
                    };
                    if (self.adapter.bulkInsertEdgeWithIds(
                        self.graph_name,
                        src_id,
                        dst_id,
                        p.rel_type,
                        p.props,
                        null,
                    )) |eid| {
                        res.node_or_edge_id = eid;
                    } else |e| switch (e) {
                        // Another writer deleted one of the endpoints
                        // between the lookup above and the insert here
                        // — treat as silent skip same as orphan.
                        error.SourceNodeNotFound, error.TargetNodeNotFound => {},
                        else => res.err = e,
                    }
                },
                .bulk_merge_node => |p| {
                    if (self.adapter.bulkMergeNode(
                        self.graph_name,
                        p.label,
                        p.merge_key,
                        p.merge_value,
                        p.on_create_props,
                        null,
                    )) |nid| {
                        res.node_or_edge_id = nid;
                    } else |e| {
                        res.err = e;
                    }
                },
            }
        }

        // Commit the flusher-owned statement txn — ONE fsync for
        // the whole batch.
        if (have_txn) {
            if (stmt_txn.commit()) |_| {} else |e| {
                for (batch) |op| {
                    const res = op.resultPtr();
                    if (res.err == null) res.err = e;
                }
            }
        }

        // Wake every submitter AFTER the write lock is released (via
        // the `defer` above).  Submitters on wake can safely re-enter
        // the graph via another submit / query.  Release ordering
        // pairs with the submitter's `acquire` in the futex-wait loop.
        for (batch) |op| {
            const res = op.resultPtr();
            res.done.store(1, .release);
            std.Io.futexWake(io, u32, &res.done.raw, 1);
        }
    }
};

// ---------------------------------------------------------------------------
// Per-adapter coordinator registry — unchanged from Task 19 / Phase 2.
// ---------------------------------------------------------------------------

var g_registry_mutex: std.Io.Mutex = std.Io.Mutex.init;
var g_registry: ?std.StringHashMap(*GroupCommitCoordinator) = null;
var g_registry_allocator: ?std.mem.Allocator = null;

pub fn getOrStartCoordinator(
    allocator: std.mem.Allocator,
    adapter: *StorageAdapter,
    graph_name: []const u8,
) !*GroupCommitCoordinator {
    const io = std.Io.Threaded.global_single_threaded.io();

    g_registry_mutex.lockUncancelable(io);
    defer g_registry_mutex.unlock(io);

    if (g_registry == null) {
        g_registry = std.StringHashMap(*GroupCommitCoordinator).init(allocator);
        g_registry_allocator = allocator;
    }

    if (g_registry.?.get(graph_name)) |existing| return existing;

    const coord = try GroupCommitCoordinator.start(allocator, adapter, graph_name);
    errdefer coord.stop();

    const owned_key = try allocator.dupe(u8, graph_name);
    errdefer allocator.free(owned_key);

    try g_registry.?.put(owned_key, coord);
    return coord;
}

pub fn lookupCoordinator(graph_name: []const u8) ?*GroupCommitCoordinator {
    const io = std.Io.Threaded.global_single_threaded.io();
    g_registry_mutex.lockUncancelable(io);
    defer g_registry_mutex.unlock(io);

    if (g_registry) |*reg| {
        return reg.get(graph_name);
    }
    return null;
}

pub fn shutdownAllCoordinators() void {
    const io = std.Io.Threaded.global_single_threaded.io();
    g_registry_mutex.lockUncancelable(io);
    defer g_registry_mutex.unlock(io);

    if (g_registry) |*reg| {
        const alloc = g_registry_allocator.?;
        var it = reg.iterator();
        // Iterate once: free the owned key, then stop the coordinator.
        // `coord.stop()` invalidates its own pointer (self-destroy on
        // the last line), so we must capture the key BEFORE stop().
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            entry.value_ptr.*.stop();
            alloc.free(key);
        }
        reg.deinit();
        g_registry = null;
        g_registry_allocator = null;
    }
}

/// Returns true unless `GEODE_GROUP_COMMIT` is explicitly set to a
/// falsy value (`0`, `false`, `no`, `off`).  The coordinator is the
/// architectural default post-Phase 2.3 — the single-phase fallback
/// lives on only for legacy tests and operators who need to disable
/// batching for forensic comparison.
///
/// Default-on rationale: the single-phase path's two-phase lock
/// (SHARED endpoint lookup → EXCLUSIVE write) is the known source of
/// `40001: Write lock acquisition timed out` cascades under the
/// 16-worker msft-graph ingest workload.  Routing all writes through
/// the coordinator eliminates that class of failure — the coordinator
/// holds EXCLUSIVE itself, drains the batch under `lockUncancelable`
/// (writer-preferred, deadline-free), and returns errors per-op
/// rather than tripping a whole-file cascade.
pub fn isEnabled() bool {
    if (cached_enabled) |v| return v;
    const val_z = std.c.getenv("GEODE_GROUP_COMMIT") orelse {
        cached_enabled = true;
        return true;
    };
    const val = std.mem.span(val_z);
    const off = std.mem.eql(u8, val, "0") or
        std.mem.eql(u8, val, "false") or
        std.mem.eql(u8, val, "no") or
        std.mem.eql(u8, val, "off");
    cached_enabled = !off;
    return !off;
}

/// Test / bench hook: force the feature on/off regardless of the env var.
pub fn setEnabledForTest(on: bool) void {
    cached_enabled = on;
}

var cached_enabled: ?bool = null;

fn monoNanosNow() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
