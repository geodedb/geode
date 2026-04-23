// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Per-graph N-way sharded group-commit coordinator (Phase 2 Task 6
//! of the graph-sharding plan, 2026-04-23).
//!
//! Previous design (Task 19 of the enterprise-ingest-throughput plan,
//! 2026-04-23 morning): ONE coordinator thread per graph.  All 16
//! ingest workers submit into a single queue; the coordinator drains
//! and applies under the single `mg.rwlock` EXCLUSIVE.  This gives
//! ~1 shard x 256-op batches and caps throughput at
//! `coordinator_apply_rate` for the hot graph.
//!
//! New design (this file): `SHARD_COUNT = 16` coordinator threads
//! per graph.  Each owns its own queue + mutex + condvar.
//! `submit(op)` pre-allocates the target node id (for node / merge
//! ops) so the shard is known BEFORE enqueue; edge ops route by
//! `shardIndex(source_id)`.  Each shard thread drains its own queue
//! independently, calling the shard-locked `*WithReservedId` /
//! `*ShardLocked` helpers (Task 5) that take `mg.rwlock` SHARED +
//! the shard's EXCLUSIVE lock.  Different shards don't serialise
//! against each other — disjoint-key concurrency is the whole
//! point of the redesign.
//!
//! Invariants preserved
//! --------------------
//! * Same public API as the single-thread coordinator: `start`,
//!   `stop`, `submit`, `getOrStartCoordinator`, `lookupCoordinator`,
//!   `shutdownAllCoordinators`, `isEnabled`, `setEnabledForTest`,
//!   `GroupCommitCoordinator` (aliased to `ShardedCoordinator`).
//! * Every submitted op still receives exactly one `done` wake-up
//!   via `std.Io.futexWake`.  Submitters that park on `done` will
//!   always observe the flip, even across thread-pool worker slot
//!   reuse.
//! * Per-op errors are still captured in `ApplyResult.err` and
//!   surface to the submitter on wake-up.  The shard thread
//!   continues with the rest of its batch so one bad op does not
//!   block N peers on the same shard.
//!
//! Threading model
//! ---------------
//! Per project convention the SHARD_COUNT long-lived shard workers
//! run on `pooled.ThreadPool` (the gitlab.com/devnw/zig/thread-pool
//! wrapper), each submitted via `submitDefault` so they share the
//! N-wide default-lane worker slots.  The pool is owned by the
//! coordinator and torn down in `stop()`.
//!
//! Env gate
//! --------
//! `GEODE_GROUP_COMMIT=1` opts into the coordinator.  Default OFF
//! so the existing single-phase path (caller holds whole-graph
//! EXCLUSIVE + calls `bulkInsertNode`) is the baseline behaviour
//! until the coordinator is validated end-to-end.

const std = @import("std");
const graph_store = @import("../graph_store.zig");
const graph_storage_adapter = @import("graph_storage_adapter.zig");
const sharded_store_lib = @import("graph_storage").sharded_store;
const pooled = @import("transport/thread_pool");

const StorageAdapter = graph_storage_adapter.StorageAdapter;
const PropKV = StorageAdapter.PropKV;
const PropertyValue = graph_store.PropertyValue;
const SHARD_COUNT = sharded_store_lib.SHARD_COUNT;

/// Tag-union of supported apply operations.  Each variant carries
/// the inputs the shard-locked bulk helpers accept plus an
/// `ApplyResult` slot that the shard thread fills in before waking
/// the submitter.  For node / merge ops, `assigned_id` is filled in
/// by `submit()` before enqueue so the shard key is known up front.
pub const ApplyOp = union(enum) {
    bulk_insert_node: struct {
        labels: []const []const u8,
        props: []const PropKV,
        result: ApplyResult,
        /// Pre-allocated by `submit()` so `shardKey()` is stable
        /// BEFORE the op is enqueued — the routing shard must be
        /// known at that point for the shard thread to receive it.
        assigned_id: u64 = 0,
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
        assigned_id: u64 = 0,
    },

    pub fn resultPtr(self: *ApplyOp) *ApplyResult {
        return switch (self.*) {
            .bulk_insert_node => |*p| &p.result,
            .bulk_insert_edge => |*p| &p.result,
            .bulk_merge_node => |*p| &p.result,
        };
    }

    /// Key that selects the shard whose worker applies this op.
    /// For node / merge inserts the assigned id is used (filled in
    /// by `submit()`); for edge inserts the source id is used so
    /// every edge leaving the same source lands on the same shard
    /// (cross-shard src != dst is handled by the helper's two-lock
    /// ascending-index acquire).
    pub fn shardKey(self: *const ApplyOp) u64 {
        return switch (self.*) {
            .bulk_insert_node => |p| p.assigned_id,
            .bulk_insert_edge => |p| p.source_id,
            .bulk_merge_node => |p| p.assigned_id,
        };
    }
};

/// One-shot result + completion signal for a submitted `ApplyOp`.
pub const ApplyResult = struct {
    node_or_edge_id: u64 = 0,
    err: ?anyerror = null,
    /// 0 = pending, 1 = done.  Waited on by submitter via `futexWait`.
    done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

/// Per-shard state inside the `ShardedCoordinator`.
const ShardState = struct {
    queue: std.Deque(*ApplyOp),
    queue_mutex: std.Io.Mutex,
    queue_not_empty: std.Io.Condition,
    ops_applied: std.atomic.Value(u64),
    batches: std.atomic.Value(u64),
};

/// N-way sharded coordinator.  `SHARD_COUNT` worker tasks drain
/// their own queues in parallel under the shard-locked write
/// protocol.
pub const ShardedCoordinator = struct {
    allocator: std.mem.Allocator,
    graph_name: []const u8, // owned
    adapter: *StorageAdapter,

    shards: [SHARD_COUNT]ShardState,
    should_stop: std.atomic.Value(u32),

    /// Long-lived thread pool hosting the shard workers.  Sized
    /// with `SHARD_COUNT + 1` so every shard worker has a
    /// default-lane slot plus one blocking-lane slot (the wrapper
    /// hardcodes `blocking_workers = 1`).
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
            .num_threads = SHARD_COUNT + 1,
            .queue_capacity = @max(SHARD_COUNT * 4, 64),
        });
        errdefer self.pool.deinit();

        // Submit SHARD_COUNT long-lived shard workers to the default
        // (non-blocking) lane so they run in parallel.  Each worker
        // runs `shardLoop` until `should_stop` flips, draining its
        // own queue.
        for (0..SHARD_COUNT) |idx| {
            const arg = try allocator.create(ShardLoopArg);
            arg.* = .{ .coord = self, .shard_idx = idx };
            const submitted = self.pool.submitDefault(.{
                .context = @ptrCast(arg),
                .callback = shardLoopEntry,
            });
            if (!submitted) {
                allocator.destroy(arg);
                self.should_stop.store(1, .release);
                // Wake any workers already running so they exit
                // promptly; the pool.deinit will then join them.
                self.wakeAllShards();
                return error.ShardSubmitFailed;
            }
        }

        return self;
    }

    pub fn stop(self: *ShardedCoordinator) void {
        self.should_stop.store(1, .release);
        self.wakeAllShards();
        // Pool deinit joins all in-flight tasks (including the
        // shard workers), with the configured 2 s deinit timeout.
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

    /// Submit an op and block until the owning shard's worker
    /// completes it.  For insert-node / merge-node ops the id is
    /// pre-allocated here so `shardKey()` is stable before enqueue.
    pub fn submit(self: *ShardedCoordinator, op: *ApplyOp) !u64 {
        // Pre-assign the id so shard routing is deterministic at
        // submit time.  The shard worker calls
        // `bulkInsertNodeWithReservedId` / `bulkMergeNodeWithReservedId`
        // which consume this id.
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
        }

        const shard_idx = sharded_store_lib.shardIndex(op.shardKey());
        const s = &self.shards[shard_idx];
        const io = std.Io.Threaded.global_single_threaded.io();

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

        // Each op takes its own shard-lock internally via the
        // `*WithReservedId` / `*ShardLocked` helpers.  No batch-
        // level statement txn is opened here — the per-op path
        // falls back to per-sub-op auto-commit txns.  Phase 3's
        // WAL flusher will batch fsyncs across shards at a lower
        // level without this file needing to open txns.
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

        // Wake every submitter after the shard locks have been
        // released inside each helper.
        for (batch) |op| {
            const res = op.resultPtr();
            res.done.store(1, .release);
            std.Io.futexWake(io, u32, &res.done.raw, 1);
        }
    }
};

/// Backwards-compatible alias — existing callers of
/// `GroupCommitCoordinator` (e.g. `quic_connection_handler`) keep
/// working without source changes.
pub const GroupCommitCoordinator = ShardedCoordinator;

// ===========================================================================
// Process-global registry (unchanged except for the type alias)
// ===========================================================================

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
    if (g_registry) |*reg| return reg.get(graph_name);
    return null;
}

pub fn shutdownAllCoordinators() void {
    const io = std.Io.Threaded.global_single_threaded.io();
    g_registry_mutex.lockUncancelable(io);
    defer g_registry_mutex.unlock(io);
    if (g_registry) |*reg| {
        const alloc = g_registry_allocator.?;
        var it = reg.iterator();
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

pub fn setEnabledForTest(on: bool) void {
    cached_enabled = on;
}

var cached_enabled: ?bool = null;
