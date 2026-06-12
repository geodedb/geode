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
const builtin = @import("builtin");
const graph_store = @import("../graph_store.zig");
const fle_integration = @import("../fle_integration.zig");
const graph_storage_adapter = @import("graph_storage_adapter.zig");
const graph_storage = @import("graph_storage");
const pooled = @import("transport/thread_pool");

const StorageAdapter = graph_storage_adapter.StorageAdapter;
const PropKV = StorageAdapter.PropKV;
const PropertyValue = graph_store.PropertyValue;

const default_shard_coalesce_wait_us: u64 = 500;
const max_shard_coalesce_wait_us: u64 = 5000;
const default_active_write_shards: u64 = graph_storage.sharded_store.SHARD_COUNT;
const unset_shard_coalesce_wait_ns = std.math.maxInt(u64);
const unset_active_write_shards = std.math.maxInt(u64);
var cached_shard_coalesce_wait_ns = std.atomic.Value(u64).init(unset_shard_coalesce_wait_ns);
var cached_active_write_shards = std.atomic.Value(u64).init(unset_active_write_shards);
var cached_phase_metrics_enabled: ?bool = null;

// CANARY: REQ=REQ-QUIC-HC-174; FEATURE="HighConcurrencyMutations"; ASPECT=ConfigurableCoordinatorCoalescing; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=storage; UPDATED=2026-05-29
//
// High-fanout QUIC mutation probes can otherwise drive the coordinator into
// mostly single-op shard batches, paying one WAL commit per mutation. A 500us
// default remains the measured stable point for the coordinator itself; the
// server/harness can still choose a narrower or wider bounded window.
fn shardCoalesceWaitNs() u64 {
    const cached = cached_shard_coalesce_wait_ns.load(.acquire);
    if (cached != unset_shard_coalesce_wait_ns) return cached;

    var wait_us = default_shard_coalesce_wait_us;
    if (std.c.getenv("GEODE_GROUP_COMMIT_COALESCE_US")) |raw_z| {
        const raw = std.mem.span(raw_z);
        if (raw.len > 0) {
            wait_us = std.fmt.parseUnsigned(u64, raw, 10) catch default_shard_coalesce_wait_us;
        }
    }
    wait_us = @min(wait_us, max_shard_coalesce_wait_us);
    const wait_ns = wait_us * std.time.ns_per_us;
    cached_shard_coalesce_wait_ns.store(wait_ns, .release);
    return wait_ns;
}

// CANARY: REQ=REQ-QUIC-HC-179; FEATURE="HighConcurrencyMutations"; ASPECT=CoordinatorActiveShardTuning; STATUS=TESTED; TEST=test_group_commit_coordinator; OWNER=storage; UPDATED=2026-05-29
//
// The sustained QUIC mutation ceiling is dominated by synchronous
// submit-and-wait time in the group-commit coordinator. With 16 storage
// shards and synchronous submitters, many shard workers still commit one-op
// batches. This bounded knob lets high-fanout probes reserve new node ids from
// only the first N write shards, increasing per-shard batch density without
// changing MERGE correctness or recovery semantics. The production default
// remains all shards until a measured sweep promotes a narrower value.
fn activeWriteShardCount() u64 {
    const cached = cached_active_write_shards.load(.acquire);
    if (cached != unset_active_write_shards) return cached;

    var active = default_active_write_shards;
    if (std.c.getenv("GEODE_GROUP_COMMIT_ACTIVE_SHARDS")) |raw_z| {
        const raw = std.mem.span(raw_z);
        if (raw.len > 0) {
            active = std.fmt.parseUnsigned(u64, raw, 10) catch default_active_write_shards;
        }
    }
    active = std.math.clamp(active, 1, @as(u64, @intCast(graph_storage.sharded_store.SHARD_COUNT)));
    cached_active_write_shards.store(active, .release);
    return active;
}

fn reserveNodeIdForActiveWriteShard() u64 {
    const store = graph_store.getGlobalStore(graph_store.global_allocator());
    const active = activeWriteShardCount();
    if (active >= graph_storage.sharded_store.SHARD_COUNT) return store.reserveNodeId();

    while (true) {
        const id = store.reserveNodeId();
        if (@as(u64, @intCast(graph_storage.sharded_store.shardIndex(id))) < active) return id;
    }
}

// CANARY: REQ=REQ-QUIC-HC-175; FEATURE="HighConcurrencyMutations"; ASPECT=CoordinatorPhaseMetrics; STATUS=IMPL; TEST=test_group_commit_coordinator; OWNER=storage; UPDATED=2026-05-29
//
// Detailed coordinator phase timings are intentionally opt-in. They require
// several monotonic-clock reads and atomics per mutation, which is useful for
// ceiling attribution but too expensive for the default high-throughput path.
fn phaseMetricsEnabled() bool {
    if (cached_phase_metrics_enabled) |enabled| return enabled;
    const val_z = std.c.getenv("GEODE_GROUP_COMMIT_PHASE_METRICS") orelse {
        cached_phase_metrics_enabled = false;
        return false;
    };
    const val = std.mem.span(val_z);
    const enabled = std.mem.eql(u8, val, "1") or
        std.mem.eql(u8, val, "true") or
        std.mem.eql(u8, val, "yes") or
        std.mem.eql(u8, val, "on");
    cached_phase_metrics_enabled = enabled;
    return enabled;
}

fn sleepNs(ns: u64) void {
    if (ns == 0) return;
    const req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

fn monoNanosNow() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    const sec: u64 = if (ts.sec < 0) 0 else @intCast(ts.sec);
    const nsec: u64 = if (ts.nsec < 0) 0 else @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

fn recordMax(counter: *std.atomic.Value(u64), sample: u64) void {
    var cur = counter.load(.monotonic);
    while (sample > cur) {
        cur = counter.cmpxchgWeak(cur, sample, .monotonic, .monotonic) orelse return;
    }
}

fn recordDuration(total: *std.atomic.Value(u64), max: *std.atomic.Value(u64), elapsed_ns: u64) void {
    _ = total.fetchAdd(elapsed_ns, .monotonic);
    recordMax(max, elapsed_ns);
}

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
        /// GAP-0891 (RC-1): the request tenant captured on the HANDLER thread
        /// in `submit()` (shard workers have no per-thread tenant / context).
        /// Borrowed for the lifetime of the blocking `submit()` — same
        /// ownership discipline as `labels`/`props` (no dupe).
        tenant: []const u8 = graph_store.DEFAULT_TENANT_ID,
    },
    bulk_insert_edge: struct {
        source_id: u64,
        target_id: u64,
        rel_type: []const u8,
        props: []const PropKV,
        result: ApplyResult,
        /// GAP-0891 (RC-1): see bulk_insert_node.tenant.
        tenant: []const u8 = graph_store.DEFAULT_TENANT_ID,
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
        /// GAP-0891 (RC-1): see bulk_insert_node.tenant.
        tenant: []const u8 = graph_store.DEFAULT_TENANT_ID,
    },
    bulk_merge_node: struct {
        label: []const u8,
        merge_key: []const u8,
        merge_value: PropertyValue,
        on_create_props: []const PropKV,
        result: ApplyResult,
        /// Reserved by Phase 2.2 stage-1 workers — see bulk_insert_node.
        assigned_id: u64 = 0,
        /// True when the originating MERGE was a bare-`SET` form
        /// (GAP #59) — the SET clauses must apply on both create and
        /// match branches.  Forwarded to
        /// `bulkMergeNodeWithReservedId(..., apply_on_match = true)`.
        apply_on_match: bool = false,
        /// GAP-0891 (RC-1): see bulk_insert_node.tenant.
        tenant: []const u8 = graph_store.DEFAULT_TENANT_ID,
    },
    // CANARY: REQ=REQ-QUIC-HC-109; FEATURE="High-Concurrency Mutations"; ASPECT=MultiPropertyMergeCoordinator; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=storage; UPDATED=2026-05-27
    bulk_merge_node_props: struct {
        label: []const u8,
        merge_props: []const PropKV,
        on_create_props: []const PropKV,
        result: ApplyResult,
        assigned_id: u64 = 0,
        /// GAP-0891 (RC-1): see bulk_insert_node.tenant.
        tenant: []const u8 = graph_store.DEFAULT_TENANT_ID,
    },

    pub fn resultPtr(self: *ApplyOp) *ApplyResult {
        return switch (self.*) {
            .bulk_insert_node => |*p| &p.result,
            .bulk_insert_edge => |*p| &p.result,
            .bulk_match_create_edge => |*p| &p.result,
            .bulk_merge_node => |*p| &p.result,
            .bulk_merge_node_props => |*p| &p.result,
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
            .bulk_merge_node_props => |p| p.assigned_id,
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
    /// CLOCK_MONOTONIC timestamp set immediately before queue insertion.
    enqueued_ns: u64 = 0,
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

/// Thread-local flag set/cleared by shardLoop. Declared in the standalone
/// shard_worker_tls.zig leaf so transactions/manager.zig can import it as a
/// named build module without pulling in group_commit's full dependency graph.
const shard_worker_tls = @import("shard_worker_tls");

/// 16-way sharded coordinator. `SHARD_COUNT` worker tasks drain their
/// own queues in parallel under the shard-locked write protocol.
pub const ShardedCoordinator = struct {
    allocator: std.mem.Allocator,
    graph_name: []const u8, // owned
    adapter: *StorageAdapter,

    shards: [graph_storage.sharded_store.SHARD_COUNT]ShardState,
    should_stop: std.atomic.Value(u32),

    pool: *pooled.ThreadPool,

    /// Cumulative number of shard-batches applied across all 16 shard workers.
    apply_batches_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Cumulative number of ops applied across all shard-batches.
    apply_ops_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Cumulative count of ops whose ApplyResult.err was set.
    apply_errors_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Submitter-side coordinator timings. These are counted per submitted op.
    submit_calls_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    submit_total_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    submit_total_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    submit_enqueue_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    submit_enqueue_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    submit_wait_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    submit_wait_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Worker-side timings. Queue wait is summed per op; other timings are per batch.
    queue_wait_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    queue_wait_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    queue_depth_max: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    coalesce_waits_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    coalesce_wait_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    coalesce_wait_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    apply_batch_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    apply_batch_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    apply_begin_txn_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    apply_begin_txn_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    apply_ops_loop_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    apply_ops_loop_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    apply_commit_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    apply_commit_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    apply_wake_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    apply_wake_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Runtime-metrics registration is per-coordinator, not per submitter.
    metrics_registered: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

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
            .metrics_registered = std.atomic.Value(u32).init(0),
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
        const collect_phase_metrics = phaseMetricsEnabled();
        const submit_start_ns = if (collect_phase_metrics) monoNanosNow() else 0;
        if (collect_phase_metrics) _ = self.submit_calls_total.fetchAdd(1, .monotonic);

        // GAP-0891 (RC-1): capture the request tenant on THIS (handler) thread,
        // where the active ExecutionContext / per-thread tenant is valid, and
        // stamp it on the op. The shard worker that drains this op has neither,
        // so without this the worker tags every bulk-written row "default". The
        // slice is borrowed (not duped): `submit()` blocks until the worker
        // wakes it, so the captured tenant outlives the apply — identical
        // ownership to the borrowed `labels`/`props` already on the op.
        const request_tenant = fle_integration.tenantPreferringActiveContext();
        switch (op.*) {
            .bulk_insert_node => |*p| p.tenant = request_tenant,
            .bulk_insert_edge => |*p| p.tenant = request_tenant,
            .bulk_match_create_edge => |*p| p.tenant = request_tenant,
            .bulk_merge_node => |*p| p.tenant = request_tenant,
            .bulk_merge_node_props => |*p| p.tenant = request_tenant,
        }

        switch (op.*) {
            .bulk_insert_node => |*p| {
                p.assigned_id = reserveNodeIdForActiveWriteShard();
            },
            .bulk_merge_node => |*p| {
                p.assigned_id = reserveNodeIdForActiveWriteShard();
            },
            .bulk_merge_node_props => |*p| {
                p.assigned_id = reserveNodeIdForActiveWriteShard();
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
                        if (collect_phase_metrics) {
                            recordDuration(&self.submit_total_ns_total, &self.submit_total_max_ns, monoNanosNow() -| submit_start_ns);
                        }
                        return 0;
                    },
                    else => return err,
                }
            },
        }

        const shard_idx = graph_storage.sharded_store.shardIndex(op.shardKey());
        const s = &self.shards[shard_idx];

        const enqueue_start_ns = if (collect_phase_metrics) monoNanosNow() else 0;
        s.queue_mutex.lockUncancelable(io);
        s.queue.pushBack(self.allocator, op) catch |err| {
            s.queue_mutex.unlock(io);
            return err;
        };
        const result = op.resultPtr();
        if (collect_phase_metrics) {
            result.enqueued_ns = monoNanosNow();
            recordMax(&self.queue_depth_max, @intCast(s.queue.len));
        }
        s.queue_not_empty.signal(io);
        s.queue_mutex.unlock(io);
        const enqueue_done_ns = if (collect_phase_metrics) monoNanosNow() else 0;
        if (collect_phase_metrics) {
            recordDuration(&self.submit_enqueue_ns_total, &self.submit_enqueue_max_ns, enqueue_done_ns -| enqueue_start_ns);
        }

        while (result.done.load(.acquire) == 0) {
            std.Io.futexWaitUncancelable(io, u32, &result.done.raw, 0);
        }
        if (collect_phase_metrics) {
            const submit_done_ns = monoNanosNow();
            recordDuration(&self.submit_wait_ns_total, &self.submit_wait_max_ns, submit_done_ns -| enqueue_done_ns);
            recordDuration(&self.submit_total_ns_total, &self.submit_total_max_ns, submit_done_ns -| submit_start_ns);
        }
        if (result.err) |e| return e;
        return result.node_or_edge_id;
    }

    /// Register the coordinator's throughput counters with the
    /// process-global runtime_metrics registry. Idempotent in the
    /// sense that a second call leaks a few `Counter` entries but
    /// does no harm. Caller is responsible for invoking this AFTER
    /// `runtime_metrics.setGlobalRegistry` has run; if the global
    /// registry is null at call time, this is a no-op.
    pub fn registerWithRuntimeMetrics(self: *ShardedCoordinator) void {
        const runtime_metrics = @import("runtime_metrics");
        const reg = runtime_metrics.globalRegistry() orelse return;
        // CANARY: REQ=REQ-QUIC-HC-133; FEATURE="HighConcurrencyMutations"; ASPECT=CoordinatorMetricsHotPath; STATUS=TESTED; TEST=tests/perf/test_group_commit_coordinator.zig; OWNER=storage; UPDATED=2026-05-28
        //
        // getOrStartCoordinator() sits on the mutation fast path. Re-registering
        // these counters for an existing coordinator appended duplicate registry
        // entries and allocated under the runtime-metrics mutex on every MERGE.
        if (self.metrics_registered.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return;
        // error-policy: A (whole block) — metric registration is best-effort
        // observability; duplicate-name or OOM failures must never block the
        // commit pipeline.
        reg.register("coord_apply_batches_total", &self.apply_batches_total) catch {};
        reg.register("coord_apply_ops_total", &self.apply_ops_total) catch {};
        reg.register("coord_apply_errors_total", &self.apply_errors_total) catch {};
        reg.register("coord_submit_calls_total", &self.submit_calls_total) catch {};
        reg.register("coord_submit_total_ns_total", &self.submit_total_ns_total) catch {};
        reg.register("coord_submit_total_max_ns", &self.submit_total_max_ns) catch {};
        reg.register("coord_submit_enqueue_ns_total", &self.submit_enqueue_ns_total) catch {};
        reg.register("coord_submit_enqueue_max_ns", &self.submit_enqueue_max_ns) catch {};
        reg.register("coord_submit_wait_ns_total", &self.submit_wait_ns_total) catch {};
        reg.register("coord_submit_wait_max_ns", &self.submit_wait_max_ns) catch {};
        reg.register("coord_queue_wait_ns_total", &self.queue_wait_ns_total) catch {};
        reg.register("coord_queue_wait_max_ns", &self.queue_wait_max_ns) catch {};
        reg.register("coord_queue_depth_max", &self.queue_depth_max) catch {};
        reg.register("coord_coalesce_waits_total", &self.coalesce_waits_total) catch {};
        reg.register("coord_coalesce_wait_ns_total", &self.coalesce_wait_ns_total) catch {};
        reg.register("coord_coalesce_wait_max_ns", &self.coalesce_wait_max_ns) catch {};
        reg.register("coord_apply_batch_ns_total", &self.apply_batch_ns_total) catch {};
        reg.register("coord_apply_batch_max_ns", &self.apply_batch_max_ns) catch {};
        reg.register("coord_apply_begin_txn_ns_total", &self.apply_begin_txn_ns_total) catch {};
        reg.register("coord_apply_begin_txn_max_ns", &self.apply_begin_txn_max_ns) catch {};
        reg.register("coord_apply_ops_loop_ns_total", &self.apply_ops_loop_ns_total) catch {};
        reg.register("coord_apply_ops_loop_max_ns", &self.apply_ops_loop_max_ns) catch {};
        reg.register("coord_apply_commit_ns_total", &self.apply_commit_ns_total) catch {};
        reg.register("coord_apply_commit_max_ns", &self.apply_commit_max_ns) catch {};
        reg.register("coord_apply_wake_ns_total", &self.apply_wake_ns_total) catch {};
        reg.register("coord_apply_wake_max_ns", &self.apply_wake_max_ns) catch {};
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
        shard_worker_tls.t_is_shard_worker = true;
        defer shard_worker_tls.t_is_shard_worker = false;

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
            // CANARY: REQ=REQ-QUIC-HC-013; FEATURE="CoordinatorMicroBatch"; ASPECT=ShardWorkerCoalescing; STATUS=IMPL; OWNER=storage; UPDATED=2026-05-26
            //
            // Submitters wait synchronously for their ApplyResult, so without a
            // short coalescing window each shard worker often wakes and drains a
            // one-item batch. That defeats the coordinator's WAL/index batching
            // under high fan-in. Drop the mutex for a brief 100us window, then
            // drain whatever arrived; low-concurrency latency only pays this
            // cost when a write is already queued.
            if (s.queue.len < max_batch and self.should_stop.load(.acquire) == 0) {
                s.queue_mutex.unlock(io);
                const collect_phase_metrics = phaseMetricsEnabled();
                const coalesce_start_ns = if (collect_phase_metrics) monoNanosNow() else 0;
                sleepNs(shardCoalesceWaitNs());
                if (collect_phase_metrics) {
                    recordDuration(&self.coalesce_wait_ns_total, &self.coalesce_wait_max_ns, monoNanosNow() -| coalesce_start_ns);
                    _ = self.coalesce_waits_total.fetchAdd(1, .monotonic);
                }
                s.queue_mutex.lockUncancelable(io);
            }
            var batch_len: usize = 0;
            while (batch_len < max_batch) : (batch_len += 1) {
                const op = s.queue.popFront() orelse break;
                batch_buf[batch_len] = op;
            }
            s.queue_mutex.unlock(io);
            if (batch_len == 0) continue;

            // applyShardBatch bumps s.batches and s.ops_applied internally
            // (pre-wake) so submitters observe them on submit-return.
            self.applyShardBatch(shard_idx, batch_buf[0..batch_len]);
        }
    }

    fn applyShardBatch(self: *ShardedCoordinator, shard_idx: usize, batch: []*ApplyOp) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const collect_phase_metrics = phaseMetricsEnabled();
        const batch_start_ns = if (collect_phase_metrics) monoNanosNow() else 0;

        if (collect_phase_metrics) {
            var queue_wait_sum_ns: u64 = 0;
            var queue_wait_max_ns: u64 = 0;
            for (batch) |op| {
                const enqueued_ns = op.resultPtr().enqueued_ns;
                if (enqueued_ns == 0) continue;
                const wait_ns = batch_start_ns -| enqueued_ns;
                queue_wait_sum_ns +|= wait_ns;
                if (wait_ns > queue_wait_max_ns) queue_wait_max_ns = wait_ns;
            }
            if (queue_wait_sum_ns != 0) {
                _ = self.queue_wait_ns_total.fetchAdd(queue_wait_sum_ns, .monotonic);
                recordMax(&self.queue_wait_max_ns, queue_wait_max_ns);
            }
        }

        // error-policy: A — graph-handle warm-up only; if it fails, the
        // statement-txn open below and every per-op bulk helper report the
        // real error through each op's res.err.
        _ = self.adapter.getOrCreateGraph(self.graph_name) catch {};

        // Task 7 (ShardedGraphEngine migration): open a statement txn pinned
        // to this worker's shard.  Each shard has its own independent
        // GraphEngine so there is no cross-shard TxnManager contention — the
        // 16 workers run in parallel without any serialisation on a shared
        // TxnManager.  All ops in the batch go through the shard-locked bulk
        // helpers which route writes to `engine.shards[shard_idx]` already;
        // the txn wraps them in a single WAL fsync, restoring the fsync
        // amortisation that commit a6cf7af7 had to remove.
        var stmt_txn: graph_storage_adapter.StatementTxn = undefined;
        var have_txn = false;
        const begin_txn_start_ns = if (collect_phase_metrics) monoNanosNow() else 0;
        if (self.adapter.beginStatementTxnForShard(self.graph_name, shard_idx, &stmt_txn)) |_| {
            have_txn = true;
        } else |_| {}
        if (collect_phase_metrics) {
            recordDuration(&self.apply_begin_txn_ns_total, &self.apply_begin_txn_max_ns, monoNanosNow() -| begin_txn_start_ns);
        }

        const ops_loop_start_ns = if (collect_phase_metrics) monoNanosNow() else 0;
        for (batch) |op| {
            const res = op.resultPtr();
            switch (op.*) {
                .bulk_insert_node => |p| {
                    // GAP-0891 (RC-1): tag with the tenant captured at submit.
                    if (self.adapter.bulkInsertNodeWithReservedIdForTenant(
                        self.graph_name,
                        p.assigned_id,
                        p.labels,
                        p.props,
                        p.tenant,
                    )) |id| {
                        res.node_or_edge_id = id;
                    } else |e| {
                        res.err = e;
                    }
                },
                .bulk_insert_edge => |p| {
                    if (self.adapter.bulkInsertEdgeWithIdsShardLockedForTenant(
                        self.graph_name,
                        p.source_id,
                        p.target_id,
                        p.rel_type,
                        p.props,
                        p.tenant,
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
                    if (self.adapter.bulkInsertEdgeWithIdsShardLockedForTenant(
                        self.graph_name,
                        p.source_id,
                        target_id,
                        p.rel_type,
                        p.props,
                        p.tenant,
                    )) |id| {
                        res.node_or_edge_id = id;
                    } else |e| switch (e) {
                        error.SourceNodeNotFound, error.TargetNodeNotFound => {},
                        else => res.err = e,
                    }
                },
                .bulk_merge_node => |p| {
                    if (self.adapter.bulkMergeNodeWithReservedIdForTenant(
                        self.graph_name,
                        p.assigned_id,
                        p.label,
                        p.merge_key,
                        p.merge_value,
                        p.on_create_props,
                        p.apply_on_match,
                        p.tenant,
                    )) |id| {
                        res.node_or_edge_id = id;
                    } else |e| {
                        res.err = e;
                    }
                },
                .bulk_merge_node_props => |p| {
                    if (self.adapter.bulkMergeNodeWithReservedIdMultiPropForTenant(
                        self.graph_name,
                        p.assigned_id,
                        p.label,
                        p.merge_props,
                        p.on_create_props,
                        p.tenant,
                    )) |id| {
                        res.node_or_edge_id = id;
                    } else |e| {
                        res.err = e;
                    }
                },
            }
        }
        if (collect_phase_metrics) {
            recordDuration(&self.apply_ops_loop_ns_total, &self.apply_ops_loop_max_ns, monoNanosNow() -| ops_loop_start_ns);
        }

        // Commit the shard-pinned statement txn — one WAL fsync covers the
        // entire batch for this shard.  On commit failure, propagate the error
        // to any ops that did not already carry a per-op error.
        const commit_start_ns = if (collect_phase_metrics) monoNanosNow() else 0;
        if (have_txn) {
            if (stmt_txn.commit()) |_| {} else |e| {
                for (batch) |op| {
                    const res = op.resultPtr();
                    if (res.err == null) res.err = e;
                }
            }
        }
        if (collect_phase_metrics) {
            recordDuration(&self.apply_commit_ns_total, &self.apply_commit_max_ns, monoNanosNow() -| commit_start_ns);
        }

        // Tally per-op outcomes BEFORE waking — once a waiter is woken,
        // its `submit()` call returns and the caller may free the op (the
        // typical pattern is a stack-allocated ApplyOp on the submitter's
        // frame), so reading `op.resultPtr()` after wake is a UAF. This
        // surfaced as a SIGABRT at this line under 16-way concurrent
        // submit in test_group_commit_coordinator. Order is: harvest
        // -> bump ALL metrics (coordinator + per-shard) -> wake.
        //
        // The per-shard `batches` / `ops_applied` bumps were historically
        // done at the call site after this method returned, but `submit()`
        // observes completion at the futexWake below — so any post-wake
        // bump is racy from the submitter's perspective (the test
        // test_sharded_coordinator_routing reads `ops_applied` immediately
        // on submit return and saw 0). Doing both bumps here, pre-wake,
        // makes both counters observable as soon as the submitter unblocks.
        const batch_len: usize = batch.len;
        var errs: u64 = 0;
        for (batch) |op| if (op.resultPtr().err != null) {
            errs += 1;
        };

        // Aggregate into coordinator-wide counters for runtime_metrics.
        _ = self.apply_batches_total.fetchAdd(1, .monotonic);
        _ = self.apply_ops_total.fetchAdd(@intCast(batch_len), .monotonic);
        if (errs > 0) _ = self.apply_errors_total.fetchAdd(errs, .monotonic);

        // Per-shard counters: must be bumped before the wake so that any
        // submitter waking up immediately can observe them (see comment
        // above re: test_sharded_coordinator_routing).
        const s = &self.shards[shard_idx];
        _ = s.batches.fetchAdd(1, .monotonic);
        _ = s.ops_applied.fetchAdd(batch_len, .monotonic);

        const wake_start_ns = if (collect_phase_metrics) monoNanosNow() else 0;
        for (batch) |op| {
            const res = op.resultPtr();
            res.done.store(1, .release);
            std.Io.futexWake(io, u32, &res.done.raw, 1);
        }
        if (collect_phase_metrics) {
            recordDuration(&self.apply_wake_ns_total, &self.apply_wake_max_ns, monoNanosNow() -| wake_start_ns);
            recordDuration(&self.apply_batch_ns_total, &self.apply_batch_max_ns, monoNanosNow() -| batch_start_ns);
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

    if (g_registry.?.get(graph_name)) |existing| {
        existing.registerWithRuntimeMetrics();
        return existing;
    }

    const coord = try ShardedCoordinator.start(allocator, adapter, graph_name);
    errdefer coord.stop();

    const owned_key = try allocator.dupe(u8, graph_name);
    errdefer allocator.free(owned_key);

    try g_registry.?.put(owned_key, coord);
    coord.registerWithRuntimeMetrics();
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

pub fn setActiveWriteShardsForTest(count: u64) void {
    if (!builtin.is_test) @compileError("test-only hook");
    const active = std.math.clamp(count, 1, @as(u64, @intCast(graph_storage.sharded_store.SHARD_COUNT)));
    cached_active_write_shards.store(active, .release);
}

var cached_enabled: ?bool = null;
