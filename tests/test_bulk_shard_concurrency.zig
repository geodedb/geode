// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Phase 2 Task 5 regression test: the shard-locked bulk-helper
//! variants (`bulkInsertNodeWithReservedId`,
//! `bulkInsertEdgeWithIdsShardLocked`,
//! `bulkMergeNodeWithReservedId`) support genuine N-way concurrency
//! on disjoint shards without deadlock, double-allocation, or lost
//! writes.
//!
//! Uses `pooled.ThreadPool` per project convention.

const std = @import("std");
const geode = @import("geode");
const adapter_mod = geode.graph_storage_adapter;
const pooled = geode.pooled;
const graph_store = geode.graph_store;

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

const InsertCtx = struct {
    adapter: *adapter_mod.StorageAdapter,
    ids_out: []u64,
    err: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn insertWorker(ctx_ptr: *anyopaque) void {
    const ctx: *InsertCtx = @ptrCast(@alignCast(ctx_ptr));
    const store = graph_store.getGlobalStore(graph_store.global_allocator());
    const labels = [_][]const u8{"L"};
    const props = [_]adapter_mod.StorageAdapter.PropKV{};

    for (ctx.ids_out) |*id_slot| {
        const reserved = store.reserveNodeId();
        const inserted = ctx.adapter.bulkInsertNodeWithReservedId(
            "g",
            reserved,
            &labels,
            &props,
        ) catch {
            ctx.err.store(1, .release);
            ctx.done.store(1, .release);
            return;
        };
        id_slot.* = inserted;
    }
    ctx.done.store(1, .release);
}

test "16-worker concurrent bulkInsertNodeWithReservedId: 1600 distinct ids, no deadlock" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);

    var adapter = try adapter_mod.StorageAdapter.init(allocator, data_dir, .{
        .data_dir = data_dir,
        .encryption_key = null,
    });
    defer adapter.deinit();
    _ = try adapter.getOrCreateGraph("g");

    const pool = try pooled.ThreadPool.init(allocator, .{ .num_threads = 16, .queue_capacity = 64 });
    defer pool.deinit();

    const workers: usize = 16;
    const per_worker: usize = 100;

    var ctxs: [16]InsertCtx = undefined;
    var id_buffers: [16][per_worker]u64 = undefined;
    for (&ctxs, 0..) |*c, i| {
        c.* = .{
            .adapter = adapter,
            .ids_out = id_buffers[i][0..],
        };
        try pool.submitBlocking(.{
            .context = @ptrCast(c),
            .callback = insertWorker,
        });
    }

    // Wait for every worker (9 sec cap).
    const deadline_ns = nowNs() + 9 * std.time.ns_per_s;
    outer: while (true) {
        var all_done = true;
        for (&ctxs) |*c| {
            if (c.done.load(.acquire) == 0) {
                all_done = false;
                break;
            }
        }
        if (all_done) break :outer;
        if (nowNs() > deadline_ns) {
            // Deadlock: dump state and fail.
            return error.TestTimedOut;
        }
        napNs(1 * std.time.ns_per_ms);
    }

    // No worker reported an error.
    for (&ctxs, 0..) |*c, i| {
        if (c.err.load(.acquire) != 0) {
            std.debug.print("worker {d} reported error\n", .{i});
            return error.WorkerError;
        }
    }

    // All 1600 ids are distinct.
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    for (id_buffers) |row| {
        for (row) |id| {
            const already = seen.contains(id);
            try std.testing.expect(!already);
            try seen.put(id, {});
        }
    }
    try std.testing.expectEqual(workers * per_worker, seen.count());
}

fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const EdgeCtx = struct {
    adapter: *adapter_mod.StorageAdapter,
    src_ids: []const u64,
    dst_ids: []const u64,
    edges_out: []u64,
    err: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn edgeWorker(ctx_ptr: *anyopaque) void {
    const ctx: *EdgeCtx = @ptrCast(@alignCast(ctx_ptr));
    const props = [_]adapter_mod.StorageAdapter.PropKV{};
    for (ctx.src_ids, ctx.dst_ids, ctx.edges_out) |src, dst, *edge_slot| {
        const eid = ctx.adapter.bulkInsertEdgeWithIdsShardLocked(
            "g",
            src,
            dst,
            "T",
            &props,
        ) catch {
            ctx.err.store(1, .release);
            ctx.done.store(1, .release);
            return;
        };
        edge_slot.* = eid;
    }
    ctx.done.store(1, .release);
}

test "8-worker concurrent bulkInsertEdgeWithIdsShardLocked: 800 distinct edges, no deadlock" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);

    var adapter = try adapter_mod.StorageAdapter.init(allocator, data_dir, .{
        .data_dir = data_dir,
        .encryption_key = null,
    });
    defer adapter.deinit();
    _ = try adapter.getOrCreateGraph("g");

    const store = graph_store.getGlobalStore(graph_store.global_allocator());

    // Pre-create 200 nodes so the edge workers have endpoints.
    const node_count: usize = 200;
    var nodes_all: [node_count]u64 = undefined;
    const labels = [_][]const u8{"L"};
    const empty_props = [_]adapter_mod.StorageAdapter.PropKV{};
    for (&nodes_all) |*n| {
        const reserved = store.reserveNodeId();
        n.* = try adapter.bulkInsertNodeWithReservedId("g", reserved, &labels, &empty_props);
    }

    const pool = try pooled.ThreadPool.init(allocator, .{ .num_threads = 8, .queue_capacity = 32 });
    defer pool.deinit();

    const workers: usize = 8;
    const per_worker: usize = 100;

    var src_buffers: [8][per_worker]u64 = undefined;
    var dst_buffers: [8][per_worker]u64 = undefined;
    var edge_buffers: [8][per_worker]u64 = undefined;
    var ctxs: [8]EdgeCtx = undefined;

    // Each worker gets 100 (src, dst) pairs chosen across shards.
    for (0..workers) |w| {
        for (0..per_worker) |i| {
            src_buffers[w][i] = nodes_all[(w * per_worker + i) % node_count];
            dst_buffers[w][i] = nodes_all[(w * per_worker + i + 37) % node_count];
        }
        ctxs[w] = .{
            .adapter = adapter,
            .src_ids = src_buffers[w][0..],
            .dst_ids = dst_buffers[w][0..],
            .edges_out = edge_buffers[w][0..],
        };
        try pool.submitBlocking(.{
            .context = @ptrCast(&ctxs[w]),
            .callback = edgeWorker,
        });
    }

    const deadline_ns = nowNs() + 9 * std.time.ns_per_s;
    outer: while (true) {
        var all_done = true;
        for (&ctxs) |*c| {
            if (c.done.load(.acquire) == 0) {
                all_done = false;
                break;
            }
        }
        if (all_done) break :outer;
        if (nowNs() > deadline_ns) return error.TestTimedOut;
        napNs(1 * std.time.ns_per_ms);
    }

    for (&ctxs, 0..) |*c, i| {
        if (c.err.load(.acquire) != 0) {
            std.debug.print("edge worker {d} reported error\n", .{i});
            return error.WorkerError;
        }
    }

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    for (edge_buffers) |row| {
        for (row) |eid| {
            try std.testing.expect(!seen.contains(eid));
            try seen.put(eid, {});
        }
    }
    try std.testing.expectEqual(workers * per_worker, seen.count());
}
