// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Phase 2 Task 4 regression test: per-shard rwlocks on ManagedGraph
//! permit concurrent EXCLUSIVE access on DIFFERENT shards.  Before
//! this change, every writer serialised through the single
//! `mg.rwlock`.  After this change, writers routed to disjoint
//! shards should not block each other.
//!
//! Uses the geode `pooled.ThreadPool` wrapper (backed by the
//! gitlab.com/devnw/zig/thread-pool dep) for all worker dispatch —
//! per project convention, parallelism goes through thread-pool
//! first, std.Thread.spawn only when thread-pool can't express the
//! need.

const std = @import("std");
const geode = @import("geode");
const adapter_mod = geode.graph_storage_adapter;
const sharded = geode.sharded_store;
const pooled = @import("geode").pooled;

fn tmpDataDir(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

fn napNs(ns: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

fn monoNanosNow() u64 {
    // Zig 0.16 cross-platform compat: std.posix.timespec maps to c.timespec on
    // macOS which is a distinct type from os.linux.timespec expected by
    // clock_gettime. Use comptime branch (mirrors test_thread_pool_lane_parallelism.zig).
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const HoldCtx = struct {
    mg: *adapter_mod.ManagedGraph,
    key: u64,
    ready: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    release: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn holdShardLock(ctx_ptr: *anyopaque) void {
    const ctx: *HoldCtx = @ptrCast(@alignCast(ctx_ptr));
    adapter_mod.acquireShardWriteLock(ctx.mg, ctx.key);
    ctx.ready.store(1, .release);
    while (ctx.release.load(.acquire) == 0) napNs(100 * std.time.ns_per_us);
    adapter_mod.releaseShardWriteLock(ctx.mg, ctx.key);
    ctx.done.store(1, .release);
}

fn waitReady(ctx: *HoldCtx) void {
    while (ctx.ready.load(.acquire) == 0) napNs(100 * std.time.ns_per_us);
}

fn waitDone(ctx: *HoldCtx) void {
    while (ctx.done.load(.acquire) == 0) napNs(100 * std.time.ns_per_us);
}

test "acquireShardWriteLock permits concurrent access to different shards" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);

    // Pick two node_ids whose shard indices differ.
    var id_shard0: u64 = 0;
    var id_shard1: u64 = 0;
    var k: u64 = 1;
    while (id_shard0 == 0 or id_shard1 == 0) : (k += 1) {
        const s = sharded.shardIndex(k);
        if (s == 0 and id_shard0 == 0) id_shard0 = k;
        if (s == 1 and id_shard1 == 0) id_shard1 = k;
    }

    var adapter = try geode.graph_storage_adapter.StorageAdapter.init(allocator, data_dir, .{
        .data_dir = data_dir,
        .encryption_key = null,
    });
    defer adapter.deinit();
    const mg = try adapter.getOrCreateGraph("g");

    const pool = try pooled.ThreadPool.init(allocator, .{ .num_threads = 2, .queue_capacity = 4 });
    defer pool.deinit();

    var ctx = HoldCtx{ .mg = mg, .key = id_shard0 };
    try pool.submitBlocking(.{
        .context = @ptrCast(&ctx),
        .callback = holdShardLock,
    });
    waitReady(&ctx);

    // Foreground: acquire shard 1 within 200 ms.  If the impl were
    // still a single rwlock this would block forever.
    const start_ns = monoNanosNow();
    adapter_mod.acquireShardWriteLock(mg, id_shard1);
    const elapsed_ns = monoNanosNow() - start_ns;
    adapter_mod.releaseShardWriteLock(mg, id_shard1);
    try std.testing.expect(elapsed_ns < 200 * std.time.ns_per_ms);

    ctx.release.store(1, .release);
    waitDone(&ctx);
}

test "acquireShardWriteLockCancelable honors deadline when contended" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);

    var adapter = try geode.graph_storage_adapter.StorageAdapter.init(allocator, data_dir, .{
        .data_dir = data_dir,
        .encryption_key = null,
    });
    defer adapter.deinit();
    const mg = try adapter.getOrCreateGraph("g");

    const pool = try pooled.ThreadPool.init(allocator, .{ .num_threads = 2, .queue_capacity = 4 });
    defer pool.deinit();

    var ctx = HoldCtx{ .mg = mg, .key = 1 };
    try pool.submitBlocking(.{
        .context = @ptrCast(&ctx),
        .callback = holdShardLock,
    });
    waitReady(&ctx);

    // Attempt to acquire the SAME key — should deadline in ~100 ms.
    const start_ns = monoNanosNow();
    const deadline = start_ns + 100 * std.time.ns_per_ms;
    const result = adapter_mod.acquireShardWriteLockCancelable(mg, 1, deadline);
    const elapsed_ns = monoNanosNow() - start_ns;

    try std.testing.expectError(error.Deadline, result);
    try std.testing.expect(elapsed_ns >= 80 * std.time.ns_per_ms);
    try std.testing.expect(elapsed_ns <= 300 * std.time.ns_per_ms);

    ctx.release.store(1, .release);
    waitDone(&ctx);
}

test "acquireWholeGraphExclusive blocks new shard writers" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);

    var adapter = try geode.graph_storage_adapter.StorageAdapter.init(allocator, data_dir, .{
        .data_dir = data_dir,
        .encryption_key = null,
    });
    defer adapter.deinit();
    const mg = try adapter.getOrCreateGraph("g");

    const pool = try pooled.ThreadPool.init(allocator, .{ .num_threads = 2, .queue_capacity = 4 });
    defer pool.deinit();

    // Foreground: hold the whole-graph EXCLUSIVE.
    adapter_mod.acquireWholeGraphExclusive(mg);

    // Background tries to take shard 3 write lock — should block
    // until we release the whole-graph EXCLUSIVE.
    const AcqCtx = struct {
        mg: *adapter_mod.ManagedGraph,
        acquired_at_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    };
    const tryAcquireShard = struct {
        fn run(ctx_ptr: *anyopaque) void {
            const a: *AcqCtx = @ptrCast(@alignCast(ctx_ptr));
            adapter_mod.acquireShardWriteLock(a.mg, 42);
            a.acquired_at_ns.store(monoNanosNow(), .release);
            adapter_mod.releaseShardWriteLock(a.mg, 42);
            a.done.store(1, .release);
        }
    }.run;

    var acq_ctx = AcqCtx{ .mg = mg };
    try pool.submitBlocking(.{
        .context = @ptrCast(&acq_ctx),
        .callback = tryAcquireShard,
    });

    const held_until_ns = monoNanosNow() + 100 * std.time.ns_per_ms;
    while (monoNanosNow() < held_until_ns) napNs(1 * std.time.ns_per_ms);
    adapter_mod.releaseWholeGraphExclusive(mg);

    while (acq_ctx.done.load(.acquire) == 0) napNs(100 * std.time.ns_per_us);
    const bg_ns = acq_ctx.acquired_at_ns.load(.acquire);
    try std.testing.expect(bg_ns >= held_until_ns);
}
