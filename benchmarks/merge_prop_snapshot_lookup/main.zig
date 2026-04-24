// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Microbenchmark: lookup throughput for `lookupMergeCandidate` with
//! N concurrent reader threads against a pre-populated store.
//!
//! Compares two configurations:
//!   baseline — snapshot forced null (every lookup falls through to
//!              the locked live-map path); mirrors pre-RCU behaviour.
//!   rcu      — snapshot published once at start; all lookups hit the
//!              lock-free fast path.

const std = @import("std");
const geode = @import("geode");
const GraphStore = geode.graph_store.GraphStore;

const LOOKUPS_PER_THREAD: usize = 200_000;
const STORE_SIZE: usize = 10_000;

fn seedStore(store: *GraphStore, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const nid = try store.createNode(&.{"User"});
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "user{d}", .{nid});
        try store.setNodeProperty(nid, "name", .{ .String = name });
    }
}

const Ctx = struct { store: *GraphStore };

fn worker(ctx: *Ctx) void {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    const seed: u64 = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    var rng = std.Random.DefaultPrng.init(seed);
    const rand = rng.random();
    var i: usize = 0;
    while (i < LOOKUPS_PER_THREAD) : (i += 1) {
        const probe_id = rand.intRangeAtMost(u64, 1, STORE_SIZE);
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "user{d}", .{probe_id}) catch continue;
        var out: u64 = 0;
        _ = ctx.store.lookupMergeCandidate("default", "User", "name", .{ .String = name }, &out);
    }
}

pub fn main(proc_init: std.process.Init.Minimal) !void {
    const allocator = std.heap.c_allocator;

    // Zig 0.16 passes argv via the Init.Minimal vector; skip argv[0]
    // (exe path), then take up to two positional args.
    const raw_argv = proc_init.args.vector;
    var mode_arg: []const u8 = "rcu";
    var threads_arg: []const u8 = "8";
    if (raw_argv.len >= 2) mode_arg = std.mem.span(raw_argv[1]);
    if (raw_argv.len >= 3) threads_arg = std.mem.span(raw_argv[2]);
    const threads = try std.fmt.parseInt(usize, threads_arg, 10);

    var store = try GraphStore.init(allocator);
    defer store.deinit();
    try seedStore(&store, STORE_SIZE);

    if (std.mem.eql(u8, mode_arg, "rcu")) {
        store.merge_prop_dirty_count.store(4096, .monotonic);
        store.publishMergePropSnapshotIfDirty(geode.graph_store.MERGE_PROP_PUBLISH_THRESHOLD);
    } else {
        // baseline: drop any snapshot so lookups fall through.
        if (store.merge_prop_snapshot.swap(null, .acq_rel)) |snap| snap.release();
    }

    var ctx = Ctx{ .store = &store };
    var ts_start: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts_start);

    const thread_list = try allocator.alloc(std.Thread, threads);
    defer allocator.free(thread_list);
    for (thread_list) |*t| t.* = try std.Thread.spawn(.{}, worker, .{&ctx});
    for (thread_list) |t| t.join();

    var ts_end: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts_end);
    const elapsed_ns: u64 = (@as(u64, @intCast(ts_end.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts_end.nsec))) -
        (@as(u64, @intCast(ts_start.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts_start.nsec)));

    const total_ops = threads * LOOKUPS_PER_THREAD;
    const ops_per_sec = @as(f64, @floatFromInt(total_ops)) * 1e9 / @as(f64, @floatFromInt(elapsed_ns));
    std.debug.print(
        "NATIVE_BENCH mode={s} threads={d} ops={d} elapsed_ms={d:.2} ops_per_sec={d:.0}\n",
        .{ mode_arg, threads, total_ops, @as(f64, @floatFromInt(elapsed_ns)) / 1e6, ops_per_sec },
    );
}
