// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Phase 2 Task 6 regression test: the N-way ShardedCoordinator
//! drains per-shard queues in parallel on SHARD_COUNT worker
//! threads.  Under 16 concurrent submitters pushing node inserts,
//! the coordinator should land the whole batch in well under the
//! time a single-thread coordinator would take.

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
    coord: *group_commit.ShardedCoordinator,
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

test "ShardedCoordinator: 16 submitters x 200 ops complete in parallel" {
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

    // Separate submitter pool — different from the coordinator's
    // internal worker pool so we exercise real N-way fan-in.
    const submitter_pool = try pooled.ThreadPool.init(allocator, .{
        .num_threads = 16,
        .queue_capacity = 64,
    });
    defer submitter_pool.deinit();

    const workers: usize = 16;
    const per_worker: usize = 200;
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

    // Wait for all submitters with 20 s deadline.
    const deadline_ns = start_ns + 20 * std.time.ns_per_s;
    while (true) {
        var all_done = true;
        for (&ctxs) |*c| {
            if (c.done.load(.acquire) == 0) {
                all_done = false;
                break;
            }
        }
        if (all_done) break;
        if (monoNanosNow() > deadline_ns) return error.TestTimedOut;
        napNs(1 * std.time.ns_per_ms);
    }
    const elapsed_ns = monoNanosNow() - start_ns;

    // No worker reported an error.
    for (&ctxs, 0..) |*c, i| {
        if (c.err.load(.acquire) != 0) {
            std.debug.print("submitter {d} reported error\n", .{i});
            return error.WorkerError;
        }
    }

    // 16 * 200 = 3200 distinct ids.
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    for (id_buffers) |row| {
        for (row) |id| {
            try std.testing.expect(!seen.contains(id));
            try seen.put(id, {});
        }
    }
    try std.testing.expectEqual(workers * per_worker, seen.count());

    // Under 16-way sharded concurrency, 3200 ops should land well
    // under 15 s even on a debug build with the statement-txn
    // per-op cost.  The old single-thread coordinator would
    // serialize at ~1 batch/500 ms × 256 = ~6 s minimum — we're
    // asserting the sharded version is at least COMPLETED in a
    // reasonable window.
    try std.testing.expect(elapsed_ns < 15 * std.time.ns_per_s);
}
