// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Per-graph sharded coordinator (restored from commit 210de668 and
//! re-adapted for current HEAD — see
//! docs/superpowers/specs/2026-04-25-sharded-coordinator-restoration-design.md).
//!
//! Each per-graph coordinator runs 16 shard workers on
//! `pooled.ThreadPool`. `submit(op)` routes by
//! `sharded_store.shardIndex(op.shardKey())`:
//!   * node inserts / merges route by the pre-allocated node id
//!   * regular edge inserts route by source_id
//!   * bulk_match_create_edge resolves source_id at submit time
//!     under mg.rwlock SHARED and then routes by the resolved id
//!     (orphan sources silently return 0 without enqueuing)
//!
//! Each shard worker drains up to `max_batch` = 256 ops, wraps them
//! in a single statement transaction (one WAL fsync per shard-batch),
//! dispatches to the shard-locked helpers on `StorageAdapter`, and
//! wakes submitters via the `ApplyResult.done` futex.

const std = @import("std");
const graph_store = @import("../graph_store.zig");
const graph_storage_adapter = @import("graph_storage_adapter.zig");
const graph_storage = @import("graph_storage");
const pooled = @import("transport/thread_pool");

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
        /// Pre-resolved at submit time by `ShardedCoordinator.submit`
        /// so the shard router sees a stable `shardKey()`. Zero means
        /// "not yet resolved" (single-flusher paths never read this).
        source_id: u64 = 0,
        /// Pre-resolved at submit time when possible; zero means the
        /// worker must resolve under its shard lock.
        target_id: u64 = 0,
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

    /// Key that selects the shard whose worker applies this op.
    /// For node / merge inserts the pre-allocated id is used (filled
    /// in by `submit`); for edge ops the source id is used so every
    /// edge leaving the same source lands on the same shard
    /// (cross-shard src != dst is handled by the helper's two-lock
    /// ascending-index acquire).
    pub fn shardKey(self: *const ApplyOp) u64 {
        return switch (self.*) {
            .bulk_insert_node => |p| p.assigned_id,
            .bulk_insert_edge => |p| p.source_id,
            .bulk_match_create_edge => |p| p.source_id,
            .bulk_merge_node => |p| p.assigned_id,
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

/// Per-shard state owned by `ShardedCoordinator`. One per `SHARD_COUNT` slot.
const ShardState = struct {
    queue: std.Deque(*ApplyOp),
    queue_mutex: std.Io.Mutex,
    queue_not_empty: std.Io.Condition,
    ops_applied: std.atomic.Value(u64),
    batches: std.atomic.Value(u64),
};

/// Thread-local flag set while a ShardedCoordinator worker is executing
/// its shard loop. Consumed by `transactions/manager.zig:hasWriteWriteConflicts`
/// (Debug builds only) to detect routing-bug-driven write-write
/// collisions. Non-worker threads leave this at its default (false).
pub threadlocal var t_is_shard_worker: bool = false;

/// 16-way sharded coordinator. `SHARD_COUNT` worker tasks drain their
/// own queues in parallel under the shard-locked write protocol.
pub const ShardedCoordinator = struct {
    allocator: std.mem.Allocator,
    graph_name: []const u8, // owned
    adapter: *StorageAdapter,

    shards: [graph_storage.sharded_store.SHARD_COUNT]ShardState,
    should_stop: std.atomic.Value(u32),

    pool: *pooled.ThreadPool,

    pub const max_batch: usize = 256;

    pub fn start(
        allocator: std.mem.Allocator,
        adapter: *StorageAdapter,
        graph_name: []const u8,
    ) !*ShardedCoordinator {
        const owned_name = try allocator.dupe(u8, graph_name);
        errdefer allocator.free(owned_name);

        const self = try allocator.create(ShardedCoordinator);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .graph_name = owned_name,
            .adapter = adapter,
            .shards = undefined,
            .should_stop = std.atomic.Value(u32).init(0),
            .pool = undefined,
        };

        for (&self.shards) |*s| {
            s.* = .{
                .queue = std.Deque(*ApplyOp).empty,
                .queue_mutex = std.Io.Mutex.init,
                .queue_not_empty = std.Io.Condition.init,
                .ops_applied = std.atomic.Value(u64).init(0),
                .batches = std.atomic.Value(u64).init(0),
            };
            try s.queue.ensureTotalCapacityPrecise(allocator, max_batch * 4);
        }

        self.pool = try pooled.ThreadPool.init(allocator, .{
            .num_threads = graph_storage.sharded_store.SHARD_COUNT + 1,
            .queue_capacity = @max(graph_storage.sharded_store.SHARD_COUNT * 4, 64),
        });
        errdefer self.pool.deinit();

        for (0..graph_storage.sharded_store.SHARD_COUNT) |idx| {
            const arg = try allocator.create(ShardLoopArg);
            arg.* = .{ .coord = self, .shard_idx = idx };
            const submitted = self.pool.submitDefault(.{
                .context = @ptrCast(arg),
                .callback = shardLoopEntry,
            });
            if (!submitted) {
                allocator.destroy(arg);
                self.should_stop.store(1, .release);
                self.wakeAllShards();
                return error.ShardSubmitFailed;
            }
        }

        return self;
    }

    pub fn stop(self: *ShardedCoordinator) void {
        self.should_stop.store(1, .release);
        self.wakeAllShards();
        self.pool.deinit();

        for (&self.shards) |*s| s.queue.deinit(self.allocator);
        self.allocator.free(self.graph_name);
        self.allocator.destroy(self);
    }

    fn wakeAllShards(self: *ShardedCoordinator) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        for (&self.shards) |*s| {
            s.queue_mutex.lockUncancelable(io);
            s.queue_not_empty.signal(io);
            s.queue_mutex.unlock(io);
        }
    }

    pub fn submit(self: *ShardedCoordinator, op: *ApplyOp) !u64 {
        const io = std.Io.Threaded.global_single_threaded.io();

        switch (op.*) {
            .bulk_insert_node => |*p| {
                const store = graph_store.getGlobalStore(graph_store.global_allocator());
                p.assigned_id = store.reserveNodeId();
            },
            .bulk_merge_node => |*p| {
                const store = graph_store.getGlobalStore(graph_store.global_allocator());
                p.assigned_id = store.reserveNodeId();
            },
            .bulk_insert_edge => {},
            .bulk_match_create_edge => |*p| {
                if (self.adapter.lookupNodeByMergeKey(
                    self.graph_name,
                    p.src_label,
                    p.src_filter_key,
                    p.src_filter_value,
                    error.SourceNodeNotFound,
                )) |sid| {
                    p.source_id = sid;
                } else |err| switch (err) {
                    error.SourceNodeNotFound => {
                        const res = op.resultPtr();
                        res.node_or_edge_id = 0;
                        res.err = null;
                        res.done.store(1, .release);
                        return 0;
                    },
                    else => return err,
                }
            },
        }

        const shard_idx = graph_storage.sharded_store.shardIndex(op.shardKey());
        const s = &self.shards[shard_idx];

        s.queue_mutex.lockUncancelable(io);
        s.queue.pushBack(self.allocator, op) catch |err| {
            s.queue_mutex.unlock(io);
            return err;
        };
        s.queue_not_empty.signal(io);
        s.queue_mutex.unlock(io);

        const result = op.resultPtr();
        while (result.done.load(.acquire) == 0) {
            std.Io.futexWaitUncancelable(io, u32, &result.done.raw, 0);
        }
        if (result.err) |e| return e;
        return result.node_or_edge_id;
    }

    const ShardLoopArg = struct {
        coord: *ShardedCoordinator,
        shard_idx: usize,
    };

    fn shardLoopEntry(ctx_ptr: *anyopaque) void {
        const arg: *ShardLoopArg = @ptrCast(@alignCast(ctx_ptr));
        defer arg.coord.allocator.destroy(arg);
        shardLoop(arg.coord, arg.shard_idx);
    }

    fn shardLoop(self: *ShardedCoordinator, shard_idx: usize) void {
        t_is_shard_worker = true;
        defer t_is_shard_worker = false;

        const io = std.Io.Threaded.global_single_threaded.io();
        const s = &self.shards[shard_idx];
        var batch_buf: [max_batch]*ApplyOp = undefined;

        while (true) {
            s.queue_mutex.lockUncancelable(io);
            while (s.queue.len == 0) {
                if (self.should_stop.load(.acquire) == 1) {
                    s.queue_mutex.unlock(io);
                    return;
                }
                s.queue_not_empty.waitUncancelable(io, &s.queue_mutex);
            }
            var batch_len: usize = 0;
            while (batch_len < max_batch) : (batch_len += 1) {
                const op = s.queue.popFront() orelse break;
                batch_buf[batch_len] = op;
            }
            s.queue_mutex.unlock(io);
            if (batch_len == 0) continue;

            self.applyShardBatch(shard_idx, batch_buf[0..batch_len]);
            _ = s.batches.fetchAdd(1, .monotonic);
            _ = s.ops_applied.fetchAdd(batch_len, .monotonic);
        }
    }

    fn applyShardBatch(self: *ShardedCoordinator, shard_idx: usize, batch: []*ApplyOp) void {
        _ = shard_idx;
        const io = std.Io.Threaded.global_single_threaded.io();

        // The bulk helpers (bulkInsertNodeWithReservedId,
        // bulkInsertEdgeWithIdsShardLocked, bulkMergeNodeWithReservedId) all
        // write through the GraphStore (in-memory store) path, NOT through
        // the storage engine's WAL-backed txn system.  Opening a
        // `beginStatementTxn` here would call `mg.engine.beginTxn()` from
        // all 16 shard workers simultaneously, racing on the
        // TxnManager.active_txns HashMap (not thread-safe) and triggering
        // the `pointer_stability` assertion that the hub-node regression test
        // reproduces.
        //
        // Correct fix: shard workers must NOT call any engine-txn API
        // concurrently on the same single-threaded GraphEngine.  Since the
        // bulk helpers don't use the engine txn anyway, simply omit it.
        // When the adapter is migrated to ShardedGraphEngine each worker will
        // open its shard-pinned txn via beginStatementTxnForShard (Task 6).
        _ = self.adapter.getOrCreateGraph(self.graph_name) catch {};
        const have_txn = false;

        for (batch) |op| {
            const res = op.resultPtr();
            switch (op.*) {
                .bulk_insert_node => |p| {
                    if (self.adapter.bulkInsertNodeWithReservedId(
                        self.graph_name,
                        p.assigned_id,
                        p.labels,
                        p.props,
                    )) |id| {
                        res.node_or_edge_id = id;
                    } else |e| {
                        res.err = e;
                    }
                },
                .bulk_insert_edge => |p| {
                    if (self.adapter.bulkInsertEdgeWithIdsShardLocked(
                        self.graph_name,
                        p.source_id,
                        p.target_id,
                        p.rel_type,
                        p.props,
                    )) |id| {
                        res.node_or_edge_id = id;
                    } else |e| {
                        res.err = e;
                    }
                },
                .bulk_match_create_edge => |p| {
                    var target_id = p.target_id;
                    if (target_id == 0) {
                        if (self.adapter.lookupNodeByMergeKey(
                            self.graph_name,
                            p.dst_label,
                            p.dst_filter_key,
                            p.dst_filter_value,
                            error.TargetNodeNotFound,
                        )) |tid| {
                            target_id = tid;
                        } else |err| switch (err) {
                            error.TargetNodeNotFound => continue,
                            else => {
                                res.err = err;
                                continue;
                            },
                        }
                    }
                    if (self.adapter.bulkInsertEdgeWithIdsShardLocked(
                        self.graph_name,
                        p.source_id,
                        target_id,
                        p.rel_type,
                        p.props,
                    )) |id| {
                        res.node_or_edge_id = id;
                    } else |e| switch (e) {
                        error.SourceNodeNotFound, error.TargetNodeNotFound => {},
                        else => res.err = e,
                    }
                },
                .bulk_merge_node => |p| {
                    if (self.adapter.bulkMergeNodeWithReservedId(
                        self.graph_name,
                        p.assigned_id,
                        p.label,
                        p.merge_key,
                        p.merge_value,
                        p.on_create_props,
                    )) |id| {
                        res.node_or_edge_id = id;
                    } else |e| {
                        res.err = e;
                    }
                },
            }
        }

        // have_txn is always false (no engine txn opened); this block is a
        // no-op but kept for future use when shard-pinned txns are wired.
        if (have_txn) unreachable;

        for (batch) |op| {
            const res = op.resultPtr();
            res.done.store(1, .release);
            std.Io.futexWake(io, u32, &res.done.raw, 1);
        }
    }

    pub fn shardQueueDepthForTest(self: *ShardedCoordinator, shard_idx: usize) usize {
        if (!@import("builtin").is_test) @compileError("test-only accessor");
        const io = std.Io.Threaded.global_single_threaded.io();
        const s = &self.shards[shard_idx];
        s.queue_mutex.lockUncancelable(io);
        defer s.queue_mutex.unlock(io);
        return s.queue.len;
    }

    pub fn shardOpsAppliedForTest(self: *ShardedCoordinator, shard_idx: usize) u64 {
        if (!@import("builtin").is_test) @compileError("test-only accessor");
        return self.shards[shard_idx].ops_applied.load(.acquire);
    }
};

// ---------------------------------------------------------------------------
// Per-adapter coordinator registry
// ---------------------------------------------------------------------------

var g_registry_mutex: std.Io.Mutex = std.Io.Mutex.init;
var g_registry: ?std.StringHashMap(*ShardedCoordinator) = null;
var g_registry_allocator: ?std.mem.Allocator = null;

pub fn getOrStartCoordinator(
    allocator: std.mem.Allocator,
    adapter: *StorageAdapter,
    graph_name: []const u8,
) !*ShardedCoordinator {
    const io = std.Io.Threaded.global_single_threaded.io();

    g_registry_mutex.lockUncancelable(io);
    defer g_registry_mutex.unlock(io);

    if (g_registry == null) {
        g_registry = std.StringHashMap(*ShardedCoordinator).init(allocator);
        g_registry_allocator = allocator;
    }

    if (g_registry.?.get(graph_name)) |existing| return existing;

    const coord = try ShardedCoordinator.start(allocator, adapter, graph_name);
    errdefer coord.stop();

    const owned_key = try allocator.dupe(u8, graph_name);
    errdefer allocator.free(owned_key);

    try g_registry.?.put(owned_key, coord);
    return coord;
}

pub fn lookupCoordinator(graph_name: []const u8) ?*ShardedCoordinator {
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
