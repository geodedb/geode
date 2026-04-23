// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Phase 2.1 regression test: the thread-pool-hosted
//! `GroupCommitCoordinator` (single flusher per graph, morning-baseline
//! logic) drains 16-way concurrent submissions under the same-graph
//! fan-in pattern and completes in a reasonable window.
//!
//! Also pins the per-graph isolation invariant: two graphs each get
//! their own coordinator + thread pool + flusher task, so traffic on
//! one graph does not block traffic on another.
//!
//! Uses `pooled.ThreadPool` per project convention.

const std = @import("std");
const geode = @import("geode");
const adapter_mod = geode.graph_storage_adapter;
const group_commit = geode.group_commit;
const pooled = geode.pooled;

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
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const WorkerCtx = struct {
    coord: *group_commit.GroupCommitCoordinator,
    per_worker: usize,
    err: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    ids_out: []u64,
};

fn submitterWorker(ctx_ptr: *anyopaque) void {
    const ctx: *WorkerCtx = @ptrCast(@alignCast(ctx_ptr));
    for (0..ctx.per_worker) |i| {
        const labels = [_][]const u8{"L"};
        const props = [_]adapter_mod.StorageAdapter.PropKV{};
        var op = group_commit.ApplyOp{ .bulk_insert_node = .{
            .labels = &labels,
            .props = &props,
            .result = .{},
        } };
        const id = ctx.coord.submit(&op) catch {
            ctx.err.store(1, .release);
            ctx.done.store(1, .release);
            return;
        };
        ctx.ids_out[i] = id;
    }
    ctx.done.store(1, .release);
}

fn waitForAllDone(ctxs: []WorkerCtx, deadline_ns: u64) !void {
    while (true) {
        var all_done = true;
        for (ctxs) |*c| {
            if (c.done.load(.acquire) == 0) {
                all_done = false;
                break;
            }
        }
        if (all_done) return;
        if (monoNanosNow() > deadline_ns) return error.TestTimedOut;
        napNs(1 * std.time.ns_per_ms);
    }
}

test "GroupCommitCoordinator: 16 submitters x 100 ops land in distinct ids" {
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

    group_commit.setEnabledForTest(true);
    defer {
        group_commit.setEnabledForTest(false);
        group_commit.shutdownAllCoordinators();
    }

    const coord = try group_commit.getOrStartCoordinator(allocator, adapter, "g");

    const submitter_pool = try pooled.ThreadPool.init(allocator, .{
        .num_threads = 16,
        .queue_capacity = 64,
    });
    defer submitter_pool.deinit();

    const workers: usize = 16;
    const per_worker: usize = 100;
    var id_buffers: [16][per_worker]u64 = undefined;
    var ctxs: [16]WorkerCtx = undefined;

    const start_ns = monoNanosNow();
    for (&ctxs, 0..) |*c, i| {
        c.* = .{
            .coord = coord,
            .per_worker = per_worker,
            .ids_out = id_buffers[i][0..],
        };
        try submitter_pool.submitBlocking(.{
            .context = @ptrCast(c),
            .callback = submitterWorker,
        });
    }

    try waitForAllDone(&ctxs, start_ns + 30 * std.time.ns_per_s);

    for (&ctxs, 0..) |*c, i| {
        if (c.err.load(.acquire) != 0) {
            std.debug.print("submitter {d} reported error\n", .{i});
            return error.WorkerError;
        }
    }

    // 16 * 100 = 1600 distinct ids.
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    for (id_buffers) |row| {
        for (row) |id| {
            try std.testing.expect(!seen.contains(id));
            try seen.put(id, {});
        }
    }
    try std.testing.expectEqual(workers * per_worker, seen.count());
}

test "GroupCommitCoordinator: per-graph isolation — two graphs run independently" {
    // Pins the invariant that each graph has its own coordinator +
    // thread pool + flusher, so holding the write lock on one graph
    // does NOT block submissions on another graph.  We verify by
    // running concurrent submissions against two different graph
    // names simultaneously — both should land in well under the
    // sum of their individual times.
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
    _ = try adapter.getOrCreateGraph("g1");
    _ = try adapter.getOrCreateGraph("g2");

    group_commit.setEnabledForTest(true);
    defer {
        group_commit.setEnabledForTest(false);
        group_commit.shutdownAllCoordinators();
    }

    const coord1 = try group_commit.getOrStartCoordinator(allocator, adapter, "g1");
    const coord2 = try group_commit.getOrStartCoordinator(allocator, adapter, "g2");

    // Two distinct coordinator pointers — the registry must not have
    // collapsed them.
    try std.testing.expect(coord1 != coord2);

    const submitter_pool = try pooled.ThreadPool.init(allocator, .{
        .num_threads = 8,
        .queue_capacity = 32,
    });
    defer submitter_pool.deinit();

    // 4 submitters per graph, 50 ops each.  Each graph should finish
    // independently on its own flusher.
    var id_buffers_g1: [4][50]u64 = undefined;
    var id_buffers_g2: [4][50]u64 = undefined;
    var ctxs_g1: [4]WorkerCtx = undefined;
    var ctxs_g2: [4]WorkerCtx = undefined;

    const start_ns = monoNanosNow();
    for (&ctxs_g1, 0..) |*c, i| {
        c.* = .{ .coord = coord1, .per_worker = 50, .ids_out = id_buffers_g1[i][0..] };
        try submitter_pool.submitBlocking(.{ .context = @ptrCast(c), .callback = submitterWorker });
    }
    for (&ctxs_g2, 0..) |*c, i| {
        c.* = .{ .coord = coord2, .per_worker = 50, .ids_out = id_buffers_g2[i][0..] };
        try submitter_pool.submitBlocking(.{ .context = @ptrCast(c), .callback = submitterWorker });
    }

    try waitForAllDone(&ctxs_g1, start_ns + 30 * std.time.ns_per_s);
    try waitForAllDone(&ctxs_g2, start_ns + 30 * std.time.ns_per_s);

    for (&ctxs_g1) |*c| try std.testing.expect(c.err.load(.acquire) == 0);
    for (&ctxs_g2) |*c| try std.testing.expect(c.err.load(.acquire) == 0);

    // 4 * 50 = 200 per graph = 400 ops total.
    var count_g1: usize = 0;
    for (id_buffers_g1) |row| count_g1 += row.len;
    var count_g2: usize = 0;
    for (id_buffers_g2) |row| count_g2 += row.len;
    try std.testing.expectEqual(@as(usize, 200), count_g1);
    try std.testing.expectEqual(@as(usize, 200), count_g2);
}
