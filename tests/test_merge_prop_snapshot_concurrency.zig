// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Stress test: N reader threads exercise the RCU `merge_prop_index`
//! fast path against a store that a writer thread concurrently extends.
//!
//! IMPORTANT — scope of the invariant asserted here:
//!
//! The RCU design makes `lookupMergeCandidate`'s SNAPSHOT fast path
//! lock-free. The FALL-THROUGH path (which hits the live
//! `merge_prop_index` directly) is NOT lock-free — callers must hold
//! `mg.rwlock.lockShared()` when taking the fall-through. A stress
//! test that has readers race writers on arbitrary keys would crash
//! in the fall-through (classic StringHashMap concurrent-put-get race).
//!
//! So this test is structured to stay on the snapshot fast path:
//!
//!   1. Writer creates SEED_COUNT nodes with stable properties. At the
//!      end of the seed phase, a snapshot is published (dirty_count
//!      exceeds the threshold).
//!   2. Readers start, probing ONLY for keys in the seeded range.
//!      Every probe hits the snapshot; strong-verify passes (seeded
//!      properties are never mutated).
//!   3. Writer continues creating MORE nodes (in a disjoint id range).
//!      These new writes extend the live map but do not mutate the
//!      seeded keys, so readers' snapshot probes keep returning
//!      consistent hits.
//!   4. Writer publishes additional snapshots as dirty_count crosses
//!      the threshold again — readers observe pointer swaps and
//!      transparently refcount the new snapshot.
//!
//! Invariants asserted:
//!   * No crash, no deadlock.
//!   * Every `.found` result matches a node the writer actually
//!     created (no false positives).
//!   * Every seeded probe returns `.found` (no false negatives on
//!     keys the snapshot is supposed to contain).

const std = @import("std");
const geode = @import("geode");
const GraphStore = geode.graph_store.GraphStore;

const READER_COUNT: usize = 16;
const SEED_COUNT: u64 = 2000; // > MERGE_PROP_PUBLISH_THRESHOLD (1024) so seed publishes
const POST_SEED_WRITES: u64 = 3000;
const PROBES_PER_READER: usize = 20_000;

const Ctx = struct {
    store: *GraphStore,
    seed_ids: []const u64, // stable: populated before readers start, never mutated
    max_seed_id: u64, // highest id among seed_ids
    start: std.atomic.Value(bool),
    done: std.atomic.Value(bool),
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
    // Busy-wait for go signal.
    while (!ctx.start.load(.acquire)) std.atomic.spinLoopHint();

    var rng = std.Random.DefaultPrng.init(seedFromClockAndThread());
    const rand = rng.random();

    var i: usize = 0;
    while (i < PROBES_PER_READER) : (i += 1) {
        // Probe ONLY seeded keys; this keeps us on the snapshot fast path.
        const idx = rand.intRangeAtMost(usize, 0, ctx.seed_ids.len - 1);
        const id = ctx.seed_ids[idx];

        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "user{d}", .{id}) catch continue;

        var out: u64 = 0;
        const r = ctx.store.lookupMergeCandidate("default", "User", "name", .{ .String = name }, &out);
        switch (r) {
            .found => {
                if (out != id) {
                    _ = ctx.false_positives.fetchAdd(1, .monotonic);
                }
            },
            .not_found, .not_indexable => {
                // Seeded keys should always hit the snapshot. If strong-
                // verify rejects (stale entry), that's a race we want
                // to surface — but since seed properties are never
                // mutated, this should never happen.
                _ = ctx.false_negatives.fetchAdd(1, .monotonic);
            },
        }
    }
}

fn writerPostSeedLoop(ctx: *Ctx) !void {
    // Create new nodes in a disjoint id range. These nodes use a
    // DIFFERENT label ("Device") so they don't collide with the
    // seeded "User" keys that readers probe — even if readers' strong-
    // verify somehow overlapped, the label check would reject them.
    var i: u64 = 0;
    while (i < POST_SEED_WRITES) : (i += 1) {
        const nid = try ctx.store.createNode(&.{"Device"});
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "device{d}", .{nid});
        try ctx.store.setNodeProperty(nid, "device_name", .{ .String = name });
    }
    ctx.done.store(true, .release);
}

test "merge_prop RCU: 16 readers + 1 writer, snapshot fast path only" {
    const allocator = std.testing.allocator;

    var store = try GraphStore.init(allocator);
    defer store.deinit();

    // Phase 1 (serial): seed nodes so the snapshot has enough entries.
    var seed_ids = try allocator.alloc(u64, SEED_COUNT);
    defer allocator.free(seed_ids);

    var max_seed_id: u64 = 0;
    {
        var i: u64 = 0;
        while (i < SEED_COUNT) : (i += 1) {
            const nid = try store.createNode(&.{"User"});
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "user{d}", .{nid});
            try store.setNodeProperty(nid, "name", .{ .String = name });
            seed_ids[i] = nid;
            if (nid > max_seed_id) max_seed_id = nid;
        }
    }

    // Force a publish so readers can always hit the fast path.
    store.merge_prop_dirty_count.store(geode.graph_store.MERGE_PROP_PUBLISH_THRESHOLD * 2, .monotonic);
    store.publishMergePropSnapshotIfDirty(geode.graph_store.MERGE_PROP_PUBLISH_THRESHOLD);
    try std.testing.expect(store.merge_prop_snapshot.load(.acquire) != null);

    // Phase 2: launch 16 readers + 1 writer (disjoint label). Readers
    // probe seeded User keys (always snapshot-backed); writer adds
    // Device nodes that don't conflict.
    var ctx = Ctx{
        .store = &store,
        .seed_ids = seed_ids,
        .max_seed_id = max_seed_id,
        .start = std.atomic.Value(bool).init(false),
        .done = std.atomic.Value(bool).init(false),
        .false_positives = std.atomic.Value(u64).init(0),
        .false_negatives = std.atomic.Value(u64).init(0),
    };

    var reader_threads: [READER_COUNT]std.Thread = undefined;
    for (&reader_threads) |*t| {
        t.* = try std.Thread.spawn(.{}, readerLoop, .{&ctx});
    }

    // Release readers and start the writer concurrently.
    ctx.start.store(true, .release);
    try writerPostSeedLoop(&ctx);
    for (reader_threads) |t| t.join();

    try std.testing.expectEqual(@as(u64, 0), ctx.false_positives.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), ctx.false_negatives.load(.monotonic));
}
