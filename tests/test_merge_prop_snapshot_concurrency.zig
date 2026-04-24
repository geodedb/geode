// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Concurrency test: N readers hammer `lookupMergeCandidate` against a
//! pre-populated, quiescent store. No concurrent writers.
//!
//! HONEST SCOPE
//! ============
//!
//! An earlier version of this test included a writer thread that created
//! new nodes in parallel with readers. That version crashed with a
//! segfault in `self.nodes.get()` (ShardedStore hash probe) because
//! `GraphStore.nodes` is NOT lock-free: the writer's `nodes.put()` for
//! a new node rehashes the inner map, and a reader's concurrent
//! `nodes.get()` takes a torn read of the bucket table.
//!
//! The RCU design in this branch only covers `merge_prop_index`. It
//! makes the snapshot PROBE lock-free, but `verifyMergeCandidate`
//! still has to call `self.nodes.get()` to check the node is live and
//! still has the expected property. That call is unsafe against a
//! concurrent `nodes.put()`.
//!
//! For `lookupMergeCandidate` to be truly lock-free against writers,
//! one of the following must also land:
//!
//!   1. An RCU snapshot over `nodes` / `node.properties`, OR
//!   2. A seqlock-style or sharded-rwlock scheme on the nodes map, OR
//!   3. An epoch-based reclamation that gates both indices.
//!
//! None of those are in this plan's scope. Until they land, the
//! production invariant remains: callers MUST hold
//! `mg.rwlock.lockShared()` around `lookupMergeCandidate`. The RCU
//! merely lets the merge-index probe skip the dedicated
//! `merge_prop_index_lock` SHARED — not the whole `mg.rwlock`.
//!
//! What this test DOES verify:
//!   * N readers hammering `lookupMergeCandidate` against a stable
//!     pre-populated store never crash, never produce false positives,
//!     and never produce false negatives for seeded keys.
//!   * The snapshot refcount machinery tolerates high-rate concurrent
//!     acquire/release without leaking or double-freeing.
//!   * Strong-verify returns consistent results under pure read load.

const std = @import("std");
const geode = @import("geode");
const GraphStore = geode.graph_store.GraphStore;

const READER_COUNT: usize = 16;
const SEED_COUNT: u64 = 2000; // > MERGE_PROP_PUBLISH_THRESHOLD so a snapshot publishes
const PROBES_PER_READER: usize = 20_000;

const Ctx = struct {
    store: *GraphStore,
    seed_ids: []const u64,
    start: std.atomic.Value(bool),
    false_positives: std.atomic.Value(u64),
    false_negatives: std.atomic.Value(u64),
};

fn seedFromClockAndThread() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    const ns: u64 = @as(u64, @intCast(ts.sec)) *% std.time.ns_per_s +% @as(u64, @intCast(ts.nsec));
    return ns ^ std.Thread.getCurrentId();
}

fn readerLoop(ctx: *Ctx) void {
    while (!ctx.start.load(.acquire)) std.atomic.spinLoopHint();

    var rng = std.Random.DefaultPrng.init(seedFromClockAndThread());
    const rand = rng.random();

    var i: usize = 0;
    while (i < PROBES_PER_READER) : (i += 1) {
        const idx = rand.intRangeAtMost(usize, 0, ctx.seed_ids.len - 1);
        const id = ctx.seed_ids[idx];

        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "user{d}", .{id}) catch continue;

        var out: u64 = 0;
        const r = ctx.store.lookupMergeCandidate("default", "User", "name", .{ .String = name }, &out);
        switch (r) {
            .found => {
                if (out != id) _ = ctx.false_positives.fetchAdd(1, .monotonic);
            },
            .not_found, .not_indexable => {
                _ = ctx.false_negatives.fetchAdd(1, .monotonic);
            },
        }
    }
}

test "merge_prop RCU: 16 readers against quiescent snapshot, zero false positives" {
    const allocator = std.testing.allocator;

    var store = try GraphStore.init(allocator);
    defer store.deinit();

    var seed_ids = try allocator.alloc(u64, SEED_COUNT);
    defer allocator.free(seed_ids);

    var i: u64 = 0;
    while (i < SEED_COUNT) : (i += 1) {
        const nid = try store.createNode(&.{"User"});
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "user{d}", .{nid});
        try store.setNodeProperty(nid, "name", .{ .String = name });
        seed_ids[i] = nid;
    }

    store.merge_prop_dirty_count.store(geode.graph_store.MERGE_PROP_PUBLISH_THRESHOLD * 2, .monotonic);
    store.publishMergePropSnapshotIfDirty(geode.graph_store.MERGE_PROP_PUBLISH_THRESHOLD);
    try std.testing.expect(store.merge_prop_snapshot.load(.acquire) != null);

    var ctx = Ctx{
        .store = &store,
        .seed_ids = seed_ids,
        .start = std.atomic.Value(bool).init(false),
        .false_positives = std.atomic.Value(u64).init(0),
        .false_negatives = std.atomic.Value(u64).init(0),
    };

    var reader_threads: [READER_COUNT]std.Thread = undefined;
    for (&reader_threads) |*t| {
        t.* = try std.Thread.spawn(.{}, readerLoop, .{&ctx});
    }

    ctx.start.store(true, .release);
    for (reader_threads) |t| t.join();

    try std.testing.expectEqual(@as(u64, 0), ctx.false_positives.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), ctx.false_negatives.load(.monotonic));
}
