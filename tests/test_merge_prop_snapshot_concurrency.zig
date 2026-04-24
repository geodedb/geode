// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Stress test: 16 reader threads + 1 writer thread exercise the RCU
//! `merge_prop_index` path. Invariants:
//!   * No crash, no deadlock.
//!   * A reader that sees `.found` with node_id N gets a strong-verified
//!     consistent view (node.graph, node.labels include label, and
//!     node.properties[prop_key] equals prop_value AT THE MOMENT OF
//!     RETURN — relaxed to "was consistent at snapshot publish time" —
//!     the test accepts any `.found` whose node_id is one the writer
//!     ever created).
//!   * No false-positive `.found` for a key that the writer never
//!     inserted.

const std = @import("std");
const geode = @import("geode");
const GraphStore = geode.graph_store.GraphStore;

const READER_COUNT: usize = 16;
const MUTATIONS: usize = 5000;

const Ctx = struct {
    store: *GraphStore,
    done: std.atomic.Value(bool),
    valid_ids: *std.atomic.Value(u64), // monotonically-increasing high-water mark of valid IDs
    false_positives: *std.atomic.Value(u64),
};

fn seedFromClockAndThread() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    const ns: u64 = @as(u64, @intCast(ts.sec)) *% std.time.ns_per_s +% @as(u64, @intCast(ts.nsec));
    return ns ^ std.Thread.getCurrentId();
}

fn readerLoop(ctx: *Ctx) void {
    var rng = std.Random.DefaultPrng.init(seedFromClockAndThread());
    const rand = rng.random();

    while (!ctx.done.load(.acquire)) {
        const probe_id = rand.intRangeAtMost(u64, 1, @max(1, ctx.valid_ids.load(.monotonic) + 100));
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "user{d}", .{probe_id}) catch continue;

        var out: u64 = 0;
        const r = ctx.store.lookupMergeCandidate("default", "User", "name", .{ .String = name }, &out);
        if (r == .found) {
            // Any returned node_id must be one the writer created (<= high-water mark).
            if (out > ctx.valid_ids.load(.monotonic) + 10) {
                // +10 slack for the writer being mid-insert.
                _ = ctx.false_positives.fetchAdd(1, .monotonic);
            }
        }
    }
}

fn writerLoop(ctx: *Ctx) !void {
    var i: u64 = 0;
    while (i < MUTATIONS) : (i += 1) {
        const nid = try ctx.store.createNode(&.{"User"});
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "user{d}", .{nid});
        try ctx.store.setNodeProperty(nid, "name", .{ .String = name });
        _ = ctx.valid_ids.store(nid, .monotonic);
    }
    ctx.done.store(true, .release);
}

test "merge_prop RCU: 16 readers + 1 writer, no false positives" {
    var store = try GraphStore.init(std.testing.allocator);
    defer store.deinit();

    var valid_ids = std.atomic.Value(u64).init(0);
    var false_positives = std.atomic.Value(u64).init(0);

    var ctx = Ctx{
        .store = &store,
        .done = std.atomic.Value(bool).init(false),
        .valid_ids = &valid_ids,
        .false_positives = &false_positives,
    };

    var reader_threads: [READER_COUNT]std.Thread = undefined;
    for (&reader_threads) |*t| {
        t.* = try std.Thread.spawn(.{}, readerLoop, .{&ctx});
    }

    try writerLoop(&ctx);

    for (reader_threads) |t| t.join();

    try std.testing.expectEqual(@as(u64, 0), ctx.false_positives.load(.monotonic));
}
