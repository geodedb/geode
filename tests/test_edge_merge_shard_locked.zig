// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// FIX #3 regression: the GQL relationship MERGE
//   MATCH (a {k}),(b {k}) MERGE (a)-[:R]->(b)
// must (1) create the relationship under PER-SHARD locks (graph rwlock SHARED +
// the two endpoint shards' EXCLUSIVE locks) so it COEXISTS with concurrent
// readers that hold the graph SHARED — instead of the whole-graph EXCLUSIVE the
// regular executor takes (which readers starve → the edge-phase 40001); and
// (2) preserve MERGE semantics: a repeat MERGE of the same (source,target,type)
// returns the SAME edge and creates NO duplicate, even under concurrent same-
// edge MERGE races.
//
// This pins the adapter primitive `bulkMergeEdgeWithIdsShardLocked` directly
// (the shard-locked, deduped edge create the relationship-MERGE fast path routes
// to after resolving endpoints by id).
//
// CANARY: REQ=REQ-CONCURRENCY-EDGE-MERGE-SHARD-LOCKED; FEATURE="EdgeMergeShardLocked"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_edge_merge_shard_locked.zig; OWNER=storage; UPDATED=2026-06-23

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;
const sharded_store = geode.sharded_store;

const GRAPH = graph_store.DEFAULT_GRAPH_NAME;
const LABEL = "Taxon";
const REL = "PARENT_OF";

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

const Env = struct {
    allocator: std.mem.Allocator,
    data_dir: []u8,
    adapter: *adapter_mod.StorageAdapter,
    store: *graph_store.GraphStore,

    fn setup(allocator: std.mem.Allocator, tmp_sub_path: []const u8) !Env {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        const data_dir = try tmpDirRealpathAlloc(allocator, tmp_sub_path);
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        _ = try execution.ensureCatalogInstance(allocator);
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
        _ = try adapter.getOrCreateGraph(GRAPH);
        return .{ .allocator = allocator, .data_dir = data_dir, .adapter = adapter, .store = store };
    }

    fn teardown(self: *Env) void {
        graph_store.deinitGlobalStore();
        execution.cleanupCatalogInstance();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
    }
};

fn makeNode(adapter: *adapter_mod.StorageAdapter, store: *graph_store.GraphStore, sid: []const u8) !u64 {
    const labels = [_][]const u8{LABEL};
    const props = [_]adapter_mod.StorageAdapter.PropKV{.{ .key = "source_id", .value = .{ .String = sid } }};
    const id = store.reserveNodeId();
    return adapter.bulkInsertNodeWithReservedId(GRAPH, id, &labels, &props);
}

// Count outgoing edges from `src` to `dst` of type REL in GRAPH.
fn countEdges(store: *graph_store.GraphStore, src: u64, dst: u64) usize {
    const outgoing = (store.getOutgoingEdgeIdsOrError(src) catch @panic("SONNY-6621: unexpected read failure")) orelse return 0;
    var n: usize = 0;
    for (outgoing) |eid| {
        const e = store.edges.getPtr(eid) orelse continue;
        if (e.to_id != dst) continue;
        if (!std.mem.eql(u8, e.graph_name, GRAPH)) continue;
        if (!std.mem.eql(u8, e.label, REL)) continue;
        n += 1;
    }
    return n;
}

test "shard-locked edge MERGE dedups: repeat MERGE returns the same edge, no duplicate" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    const a = try makeNode(env.adapter, env.store, "A");
    const b = try makeNode(env.adapter, env.store, "B");

    const id1 = try env.adapter.bulkMergeEdgeWithIdsShardLocked(GRAPH, a, b, REL, &.{});
    const id2 = try env.adapter.bulkMergeEdgeWithIdsShardLocked(GRAPH, a, b, REL, &.{});
    const id3 = try env.adapter.bulkMergeEdgeWithIdsShardLocked(GRAPH, a, b, REL, &.{});

    try testing.expectEqual(id1, id2);
    try testing.expectEqual(id1, id3);
    try testing.expectEqual(@as(usize, 1), countEdges(env.store, a, b));
}

test "shard-locked edge MERGE: distinct target / type create distinct edges" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    const a = try makeNode(env.adapter, env.store, "A");
    const b = try makeNode(env.adapter, env.store, "B");
    const c = try makeNode(env.adapter, env.store, "C");

    const e_ab = try env.adapter.bulkMergeEdgeWithIdsShardLocked(GRAPH, a, b, REL, &.{});
    const e_ac = try env.adapter.bulkMergeEdgeWithIdsShardLocked(GRAPH, a, c, REL, &.{});
    const e_ab2 = try env.adapter.bulkMergeEdgeWithIdsShardLocked(GRAPH, a, b, "ACCEPTED_AS", &.{});

    try testing.expect(e_ab != e_ac);
    try testing.expect(e_ab != e_ab2);
    try testing.expectEqual(@as(usize, 1), countEdges(env.store, a, b)); // only the PARENT_OF
    try testing.expectEqual(@as(usize, 1), countEdges(env.store, a, c));
}

test "shard-locked edge MERGE: missing endpoint is reported (orphan skip)" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    const a = try makeNode(env.adapter, env.store, "A");
    const bogus_target: u64 = 9_999_999;

    try testing.expectError(error.TargetNodeNotFound, env.adapter.bulkMergeEdgeWithIdsShardLocked(GRAPH, a, bogus_target, REL, &.{}));
}

const RaceCtx = struct {
    adapter: *adapter_mod.StorageAdapter,
    a: u64,
    b: u64,
    start: *std.atomic.Value(bool),
    err: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn mergeWorker(ctx: *RaceCtx) void {
    while (!ctx.start.load(.acquire)) std.atomic.spinLoopHint();
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        _ = ctx.adapter.bulkMergeEdgeWithIdsShardLocked(GRAPH, ctx.a, ctx.b, REL, &.{}) catch {
            ctx.err.store(true, .release);
            return;
        };
    }
}

test "shard-locked edge MERGE is race-safe: concurrent same-edge MERGE yields exactly one edge" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    const a = try makeNode(env.adapter, env.store, "A");
    const b = try makeNode(env.adapter, env.store, "B");

    var start = std.atomic.Value(bool).init(false);
    var ctx = RaceCtx{ .adapter = env.adapter, .a = a, .b = b, .start = &start };

    const num_workers = 8;
    var threads: [num_workers]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, mergeWorker, .{&ctx});
    start.store(true, .release);
    for (&threads) |t| t.join();

    try testing.expect(!ctx.err.load(.acquire));
    // MERGE semantics under race: exactly ONE edge despite 8×50 concurrent
    // MERGE calls for the same (source,target,type).
    try testing.expectEqual(@as(usize, 1), countEdges(env.store, a, b));
}

const ReaderCtx = struct {
    stop: *std.atomic.Value(bool),
};

// A reader holding the graph SHARED lock back-to-back (the analytical-scan /
// checkpoint reader). The shard-locked MERGE takes graph SHARED too, so it must
// COEXIST — never blocked by the reader (no whole-graph exclusive).
fn readerChurn(ctx: *ReaderCtx) void {
    while (!ctx.stop.load(.acquire)) {
        const h = graph_store.acquireGraphReadLockTagged(GRAPH, .misc);
        std.atomic.spinLoopHint();
        graph_store.releaseGraphLock(h);
    }
}

test "shard-locked edge MERGE coexists with a continuous graph-SHARED reader" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    const a = try makeNode(env.adapter, env.store, "A");
    const b = try makeNode(env.adapter, env.store, "B");

    var stop = std.atomic.Value(bool).init(false);
    var rctx = ReaderCtx{ .stop = &stop };
    const num_readers = 4;
    var readers: [num_readers]std.Thread = undefined;
    for (&readers) |*t| t.* = try std.Thread.spawn(.{}, readerChurn, .{&rctx});
    defer {
        stop.store(true, .release);
        for (&readers) |t| t.join();
    }
    sleepMs(20); // steady-state contention

    // 200 MERGEs against distinct targets while readers hammer graph SHARED.
    // Must all complete promptly (shard locks coexist with graph SHARED).
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var buf: [16]u8 = undefined;
        const sid = std.fmt.bufPrint(&buf, "t{d}", .{i}) catch unreachable;
        const t = try makeNode(env.adapter, env.store, sid);
        _ = try env.adapter.bulkMergeEdgeWithIdsShardLocked(GRAPH, a, t, REL, &.{});
    }
    // The original a->b is still mergeable (dedup) under reader contention.
    const id1 = try env.adapter.bulkMergeEdgeWithIdsShardLocked(GRAPH, a, b, REL, &.{});
    const id2 = try env.adapter.bulkMergeEdgeWithIdsShardLocked(GRAPH, a, b, REL, &.{});
    try testing.expectEqual(id1, id2);
    try testing.expectEqual(@as(usize, 1), countEdges(env.store, a, b));
}
