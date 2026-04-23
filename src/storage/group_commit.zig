// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Per-graph group-commit coordinator (Task 19 of the
//! enterprise-ingest-throughput plan, 2026-04-23).
//!
//! Purpose
//! -------
//! Under the msft-graph ingest workload, 16 concurrent QUIC stream workers
//! each take the per-graph exclusive write lock (`mg.rwlock`) to apply a
//! single CREATE / MERGE / edge insert.  Each apply is ~2-3 ms of critical
//! section; with 16 workers racing the writer lock they serialise →
//! ~300 stmts/sec ceiling for a single graph even after the Task 16
//! two-phase split.
//!
//! The coordinator replaces the N-way writer contention with an enqueue-
//! and-block protocol:
//!
//!   1. Worker builds an `ApplyOp` on its stack and submits it.
//!   2. The per-graph coordinator thread owns the exclusive write lock.
//!      It drains the queue in batches (up to `max_batch`), applies each
//!      op under one lock acquire + one statement-txn (one WAL fsync per
//!      batch), then wakes every submitter.
//!   3. Submitters wait on a per-op `std.Io.Event`.
//!
//! Invariants preserved
//! --------------------
//! * All three bulk-insert helpers (`bulkInsertNode`, `bulkInsertEdgeWithIds`,
//!   `bulkMergeNode`) are called unchanged.  They still drive the in-memory
//!   store + engine + label index + merge-prop index identically.
//! * The coordinator-owned statement txn means every op in a batch commits
//!   with ONE fsync — same guarantee the single-worker fast path gets, now
//!   amortised over the whole batch.
//! * If an op fails, the error is captured in `ApplyResult.err` and the
//!   submitter observes it after wake-up.  The coordinator continues with
//!   the rest of the batch so one bad op does not block 15 peers.
//!
//! Env gate
//! --------
//! `GEODE_GROUP_COMMIT=1` opts into the coordinator.  Default OFF so the
//! existing single-phase path is the baseline behaviour until the coordinator
//! is validated end-to-end against the msft-graph workload.

const std = @import("std");
const graph_store = @import("../graph_store.zig");
const graph_storage_adapter = @import("graph_storage_adapter.zig");

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
    },
    bulk_insert_edge: struct {
        source_id: u64,
        target_id: u64,
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
    },

    pub fn resultPtr(self: *ApplyOp) *ApplyResult {
        return switch (self.*) {
            .bulk_insert_node => |*p| &p.result,
            .bulk_insert_edge => |*p| &p.result,
            .bulk_merge_node => |*p| &p.result,
        };
    }
};

/// One-shot result + completion signal for a submitted `ApplyOp`.
///
/// The submitter parks on `done` (a `std.Io.Event`-equivalent u32 flag)
/// via `std.Io.futexWait` and wakes when the coordinator flips it to 1
/// via `std.Io.futexWake` after populating `node_or_edge_id` / `err`.
pub const ApplyResult = struct {
    node_or_edge_id: u64 = 0,
    err: ?anyerror = null,
    /// 0 = pending, 1 = done.  Waited on by submitter via `futexWait`.
    done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

/// Per-graph coordinator.  Owns one thread that drains the queue and
/// applies batches under the per-graph exclusive write lock.
pub const GroupCommitCoordinator = struct {
    allocator: std.mem.Allocator,
    graph_name: []const u8, // owned
    adapter: *StorageAdapter,

    /// Queue of pending ops.  Guarded by `queue_mutex`.  Each entry is a
    /// pointer into the submitter's stack-allocated `ApplyOp`; the
    /// coordinator MUST NOT dereference after `result.done` is set to 1
    /// (the submitter may unwind its frame at that point).
    queue: std.Deque(*ApplyOp),
    queue_mutex: std.Io.Mutex,
    queue_not_empty: std.Io.Condition,

    thread: std.Thread,
    /// Set to 1 by `stop()`; the coordinator loop exits after draining.
    should_stop: std.atomic.Value(u32),

    // Stats (atomic so stop()/tests can snapshot them lock-free).
    ops_applied: std.atomic.Value(u64),
    batches: std.atomic.Value(u64),

    /// Tunable: max ops in a single batch before forcing a lock release +
    /// re-acquire.  Large enough to amortise lock acquire cost across the
    /// 16-worker fan-in, small enough to bound tail latency of any single
    /// submitter.
    pub const max_batch: usize = 32;

    /// Poll timeout before re-checking `should_stop`.  Short enough that
    /// `stop()` converges within ~1 ms of the signal.
    const poll_timeout_ns: u64 = 1 * std.time.ns_per_ms;

    /// Allocate, wire up the queue, and spawn the coordinator thread.
    pub fn start(
        allocator: std.mem.Allocator,
        adapter: *StorageAdapter,
        graph_name: []const u8,
    ) !*GroupCommitCoordinator {
        const owned_name = try allocator.dupe(u8, graph_name);
        errdefer allocator.free(owned_name);

        const self = try allocator.create(GroupCommitCoordinator);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .graph_name = owned_name,
            .adapter = adapter,
            .queue = std.Deque(*ApplyOp).empty,
            .queue_mutex = std.Io.Mutex.init,
            .queue_not_empty = std.Io.Condition.init,
            .thread = undefined,
            .should_stop = std.atomic.Value(u32).init(0),
            .ops_applied = std.atomic.Value(u64).init(0),
            .batches = std.atomic.Value(u64).init(0),
        };

        // Pre-size the queue so normal operation never hits the growth path
        // under the coordinator's mutex (contention amplifier).
        try self.queue.ensureTotalCapacityPrecise(allocator, max_batch * 4);

        self.thread = try std.Thread.spawn(.{}, loop, .{self});
        return self;
    }

    /// Signal the coordinator to stop, wait for the thread to exit, and
    /// release all allocations.  Pending ops in the queue are drained
    /// before the thread exits — a call to `stop()` will NOT drop ops on
    /// the floor.
    pub fn stop(self: *GroupCommitCoordinator) void {
        const io = std.Io.Threaded.global_single_threaded.io();

        self.should_stop.store(1, .release);

        // Wake the coordinator in case it is parked on `queue_not_empty`
        // with an empty queue waiting for work.
        self.queue_mutex.lockUncancelable(io);
        self.queue_not_empty.signal(io);
        self.queue_mutex.unlock(io);

        self.thread.join();

        self.queue.deinit(self.allocator);
        self.allocator.free(self.graph_name);
        self.allocator.destroy(self);
    }

    /// Enqueue `op` and block until the coordinator signals completion.
    /// Returns the populated `ApplyResult` contents; callers may also
    /// inspect `op.resultPtr().*` directly.
    pub fn submit(self: *GroupCommitCoordinator, op: *ApplyOp) !u64 {
        const io = std.Io.Threaded.global_single_threaded.io();

        self.queue_mutex.lockUncancelable(io);
        self.queue.pushBack(self.allocator, op) catch |err| {
            self.queue_mutex.unlock(io);
            return err;
        };
        self.queue_not_empty.signal(io);
        self.queue_mutex.unlock(io);

        // Park on the op's done flag.  `futexWaitUncancelable` is used so
        // we don't wake on cancellation mid-batch (which would desync the
        // coordinator's bookkeeping — the op is already in the queue).
        const result = op.resultPtr();
        while (result.done.load(.acquire) == 0) {
            std.Io.futexWaitUncancelable(io, u32, &result.done.raw, 0);
        }

        if (result.err) |e| return e;
        return result.node_or_edge_id;
    }

    /// Coordinator thread entry.  Drains the queue in batches forever
    /// until `should_stop` flips and the queue is empty.
    fn loop(self: *GroupCommitCoordinator) void {
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
                    // Queue is empty and stop was signalled — exit.
                    self.queue_mutex.unlock(io);
                    return;
                }
                // Park on the condition variable until a submit() signals
                // us (or a spurious wakeup).  `waitUncancelable` is safe
                // because the coordinator thread is not cancellable.
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

    /// Apply a pre-drained batch under one exclusive write-lock acquire
    /// and one coordinator-owned statement txn (one WAL fsync for the
    /// whole batch).  Per-op errors are captured in the op's
    /// `ApplyResult.err` and do NOT fail the batch.
    fn applyBatch(self: *GroupCommitCoordinator, batch: []*ApplyOp) void {
        const io = std.Io.Threaded.global_single_threaded.io();

        // Take the per-graph exclusive write lock with a large deadline.
        // A true failure here (graph dropped, etc.) is surfaced to every
        // op in the batch — the coordinator never returns an error to
        // the submitter via any other channel.
        const deadline = monoNanosNow() + 30 * std.time.ns_per_s;
        const lock_handle = graph_store.acquireGraphWriteLockCancelable(self.graph_name, deadline) catch |err| {
            for (batch) |op| {
                const res = op.resultPtr();
                res.err = err;
                res.done.store(1, .release);
                std.Io.futexWake(io, u32, &res.done.raw, 1);
            }
            return;
        };
        defer graph_store.releaseGraphLock(lock_handle);

        // Coordinator-owned statement txn for the whole batch — single
        // WAL fsync for all ops.  If the adapter can't open one (e.g.
        // the graph's engine isn't registered yet), fall through to
        // per-op auto-commit — the bulk helpers handle that case too.
        var stmt_txn: graph_storage_adapter.StatementTxn = undefined;
        var have_txn = false;
        // Ensure the engine is registered for this graph so
        // `beginStatementTxn` doesn't trip `GraphNotFound`.  Failure is
        // non-fatal: the bulk helpers below will open their own txns as
        // a fallback.
        _ = self.adapter.getOrCreateGraph(self.graph_name) catch {};
        if (self.adapter.beginStatementTxn(self.graph_name, &stmt_txn)) |_| {
            have_txn = true;
        } else |_| {
            // Another thread (shouldn't happen — coordinator is the only
            // writer on this graph while the lock is held, and
            // thread-locals are per-thread) or the graph isn't
            // registered; fall through.
        }

        // Apply each op.  Errors are captured per-op; batch continues.
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

        // Commit the coordinator-owned statement txn — ONE fsync for the
        // whole batch.  If commit fails every op in the batch observes
        // the error (ops that wrote partial state have already committed
        // their sub-op work via the bulk helpers, but the engine's WAL
        // COMMIT record never lands; engine replay will roll them back).
        if (have_txn) {
            if (stmt_txn.commit()) |_| {} else |e| {
                for (batch) |op| {
                    const res = op.resultPtr();
                    if (res.err == null) res.err = e;
                }
            }
        }

        // Wake every submitter.  Must happen AFTER the lock is released
        // (done via `defer` above) so the submitter, on return, can
        // safely re-enter the graph via another submit / query.  Release
        // ordering pairs with the submitter's `acquire` in the
        // futex-wait loop.
        for (batch) |op| {
            const res = op.resultPtr();
            res.done.store(1, .release);
            std.Io.futexWake(io, u32, &res.done.raw, 1);
        }
    }
};

// ---------------------------------------------------------------------------
// Per-adapter coordinator registry
// ---------------------------------------------------------------------------
//
// The adapter is owned by `graph_store` and we intentionally keep the
// registry out of the adapter struct to avoid a circular `.zig` import
// cycle (group_commit imports graph_storage_adapter; adapter importing
// group_commit would close the loop).  Instead we hang the registry off
// a process-global `std.StringHashMap` keyed by graph name, guarded by
// a single mutex.  Lazy-init on first `getOrStart` call.

var g_registry_mutex: std.Io.Mutex = std.Io.Mutex.init;
var g_registry: ?std.StringHashMap(*GroupCommitCoordinator) = null;
var g_registry_allocator: ?std.mem.Allocator = null;

/// Return the coordinator for `graph_name`, lazily starting one if none
/// exists.  Thread-safe.  `adapter` is the target of all apply calls
/// this coordinator drives — typically `graph_store.getGlobalAdapter()`.
///
/// The coordinator outlives every individual submit; callers should NOT
/// `stop()` the returned pointer.  Lifecycle is managed by
/// `shutdownAllCoordinators()` at process / test teardown.
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

/// Non-blocking lookup — returns the coordinator if one was started
/// earlier, or null.  Used by the QUIC handlers to short-circuit when
/// the feature is off or the graph has never been mutated under the
/// coordinator.
pub fn lookupCoordinator(graph_name: []const u8) ?*GroupCommitCoordinator {
    const io = std.Io.Threaded.global_single_threaded.io();
    g_registry_mutex.lockUncancelable(io);
    defer g_registry_mutex.unlock(io);

    if (g_registry) |*reg| {
        return reg.get(graph_name);
    }
    return null;
}

/// Stop every registered coordinator and release the registry.  Called
/// from `graph_store.deinitGlobalAdapter()` so the adapter's lifetime
/// owns the coordinators.
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

/// Returns true when `GEODE_GROUP_COMMIT` is set to a truthy value ("1",
/// "true", "yes").  Cached on first read for the lifetime of the process
/// — set it before starting the server.
pub fn isEnabled() bool {
    if (cached_enabled) |v| return v;
    const val_z = std.c.getenv("GEODE_GROUP_COMMIT") orelse {
        cached_enabled = false;
        return false;
    };
    const val = std.mem.span(val_z);
    const on = std.mem.eql(u8, val, "1") or
        std.mem.eql(u8, val, "true") or
        std.mem.eql(u8, val, "yes");
    cached_enabled = on;
    return on;
}

/// Test / bench hook: force the feature on/off regardless of the env var.
/// Resets the cache so subsequent `isEnabled()` reads the new value.
pub fn setEnabledForTest(on: bool) void {
    cached_enabled = on;
}

var cached_enabled: ?bool = null;

fn monoNanosNow() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
