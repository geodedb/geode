// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! GAP-0894 regression: single-property bulk MERGE must serialize only
//! same-key writers via the striped `merge_tuple_locks` table — exactly
//! like the multi-property path — instead of taking the graph-global
//! `merge_prop_index_lock` EXCLUSIVE on every insert. Before the fix
//! `merge_tuple_lock_acquired_total` stays 0 and N concurrent workers
//! serialize on one global exclusive lock (~50 nodes/sec in the divelife
//! 14.27M bulk seed). After the fix the counter is > 0 and disjoint keys
//! insert in parallel.

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

fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn deadlockDeadlineNs(local_secs: u64) u64 {
    const in_ci = std.c.getenv("CI") != null or std.c.getenv("GITLAB_CI") != null;
    const secs: u64 = if (in_ci) 1800 else local_secs;
    return nowNs() + secs * std.time.ns_per_s;
}

const MergeCtx = struct {
    adapter: *adapter_mod.StorageAdapter,
    keys: []const i64,
    ids_out: []u64,
    err: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn mergeWorker(ctx_ptr: *anyopaque) void {
    const ctx: *MergeCtx = @ptrCast(@alignCast(ctx_ptr));
    const store = graph_store.getGlobalStore(graph_store.global_allocator());
    const empty = [_]adapter_mod.StorageAdapter.PropKV{};
    for (ctx.keys, ctx.ids_out) |k, *slot| {
        const reserved = store.reserveNodeId();
        const id = ctx.adapter.bulkMergeNodeWithReservedId(
            "g",
            reserved,
            "Taxon",
            "taxon_id",
            .{ .Int = k },
            &empty,
            false, // not apply_on_match
        ) catch {
            ctx.err.store(1, .release);
            ctx.done.store(1, .release);
            return;
        };
        slot.* = id;
    }
    ctx.done.store(1, .release);
}

test "GAP-0894: concurrent single-property MERGE stripes through merge_tuple_locks" {
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
    const mg = try adapter.getOrCreateGraph("g");

    const workers: usize = 8;
    const per_worker: usize = 100;
    var key_rows: [workers][per_worker]i64 = undefined;
    for (&key_rows, 0..) |*row, w| {
        for (row, 0..) |*slot, i| slot.* = @intCast(w * per_worker + i);
    }

    const pool = try pooled.ThreadPool.init(allocator, .{ .num_threads = 8, .queue_capacity = 32 });
    defer pool.deinit();

    var ctxs: [workers]MergeCtx = undefined;
    var id_rows: [workers][per_worker]u64 = undefined;
    for (&ctxs, 0..) |*c, w| {
        c.* = .{ .adapter = adapter, .keys = key_rows[w][0..], .ids_out = id_rows[w][0..] };
        try pool.submitBlocking(.{ .context = @ptrCast(c), .callback = mergeWorker });
    }

    const deadline_ns = deadlockDeadlineNs(60);
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
            std.debug.print("merge worker {d} reported error\n", .{i});
            return error.WorkerError;
        }
    }

    // CORE GAP-0894 ASSERTION: single-property MERGE now exercises the
    // striped per-tuple lock table. Before the fix this is exactly 0.
    try std.testing.expect(mg.merge_tuple_lock_acquired_total.load(.monotonic) > 0);

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    for (id_rows) |row| {
        for (row) |id| {
            try std.testing.expect(!seen.contains(id));
            try seen.put(id, {});
        }
    }
    try std.testing.expectEqual(workers * per_worker, seen.count());
}
