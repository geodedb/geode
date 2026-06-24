// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// PHASE 4 (edge-engine-direct): low-contention apply — the popular-parent
// EDGE throughput A/B + re-shard correctness.
//
// Problem #2 (the 313/s caveat): a kingdom/genus with millions of children is
// the SOURCE of every PARENT_OF edge, so before Phase 4 the coordinator routed
// ALL of one parent's edges to ONE shard worker (shardKey == source_id) and the
// apply took that source's shard rwlock EXCLUSIVE per op. Nodes spread across 16
// shards (~3,300/s); one popular parent did not (~313/s).
//
// Phase 4 re-shards the coordinator off source_id (hash the EDGE TUPLE
// (source,target,rel) so a popular parent's edges fan out across all 16 workers)
// and batches the same-source-engine-shard appends under ONE short exclusive
// hold instead of acquire/release-per-op. The O(degree) dedup is already gone
// (Phase 3 O(1) existence index). What remains is pure lock/queue serialization
// + per-op churn — this file measures it and guards the win.
//
// CANARY: REQ=REQ-PERF-EDGE-POPULAR-PARENT; FEATURE="EdgePopularParentThroughput"; ASPECT=Throughput+ReshardCorrectness; STATUS=TESTED; TEST=tests/test_edge_popular_parent_throughput.zig; OWNER=storage; UPDATED=2026-06-24

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_storage = @import("graph_storage");

const execution = geode.execution;
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;
const group_commit = geode.group_commit;
const sharded_store = geode.sharded_store;

const GRAPH = graph_store.DEFAULT_GRAPH_NAME;
const LABEL = "Taxon";
const PARENT_OF = "PARENT_OF";
const ACCEPTED_AS = "ACCEPTED_AS";

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// libc setenv shim (std.c has no setenv binding in this Zig). Mirrors the
// pattern in src/fle_integration.zig.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn monoNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const Env = struct {
    allocator: std.mem.Allocator,
    data_dir: []u8,
    adapter: *adapter_mod.StorageAdapter,
    store: *graph_store.GraphStore,

    fn setup(allocator: std.mem.Allocator, tmp_sub_path: []const u8) !Env {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        // Measure under the SAME WAL mode the cited baselines used: the 14.27M
        // production ingest (nodes ~3,300/s, edges ~313/s) ran with
        // GEODE_WAL_SYNC=deferred (the replayable bulk-seed mode). Deferred WAL
        // removes the per-commit fsync so the measurement isolates the LOCK /
        // QUEUE serialization that Phase 4 targets (under sync_each_commit the
        // per-edge fsync dominates and masks contention). setenv BEFORE the
        // first getGlobalStore so the adapter init reads it.
        _ = setenv("GEODE_WAL_SYNC", "deferred", 1);
        const data_dir = try tmpDirRealpathAlloc(allocator, tmp_sub_path);
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        _ = try execution.ensureCatalogInstance(allocator);
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
        _ = try adapter.getOrCreateGraph(GRAPH);
        return .{ .allocator = allocator, .data_dir = data_dir, .adapter = adapter, .store = store };
    }

    fn teardown(self: *Env) void {
        group_commit.shutdownAllCoordinators();
        group_commit.setEnabledForTest(false);
        graph_store.deinitGlobalStore();
        execution.cleanupCatalogInstance();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
    }
};

fn makeNode(env: *Env, sid: []const u8) !u64 {
    const labels = [_][]const u8{LABEL};
    const props = [_]adapter_mod.StorageAdapter.PropKV{.{ .key = "source_id", .value = .{ .String = sid } }};
    const id = env.store.reserveNodeId();
    return env.adapter.bulkInsertNodeWithReservedId(GRAPH, id, &labels, &props);
}

// Reserve a node id that lands on a specific geode shard (== engine shard, since
// slots are allocated on shardIndex(public_id)). Diagnostic helper to isolate
// the cross-shard 2PC cost from same-shard append cost.
fn makeNodeOnShard(env: *Env, sid: []const u8, want_shard: usize) !u64 {
    const labels = [_][]const u8{LABEL};
    const props = [_]adapter_mod.StorageAdapter.PropKV{.{ .key = "source_id", .value = .{ .String = sid } }};
    var id = env.store.reserveNodeId();
    var spins: usize = 0;
    while (sharded_store.shardIndex(id) != want_shard) : (spins += 1) {
        id = env.store.reserveNodeId();
        if (spins > 1_000_000) return error.ShardReserveExhausted;
    }
    return env.adapter.bulkInsertNodeWithReservedId(GRAPH, id, &labels, &props);
}

// Count outgoing edges of type `rel` from `src` to `dst` (resident mirror is
// engine-direct/bounded post Phase-1, but small here so it stays resident).
fn countEdgesTo(env: *Env, src: u64, dst: u64, rel: []const u8) usize {
    const outgoing = env.store.getOutgoingEdgeIds(src) orelse return 0;
    var n: usize = 0;
    for (outgoing) |eid| {
        const e = env.store.getEdgePtrHydrated(eid) orelse continue;
        if (e.to_id != dst) continue;
        if (!std.mem.eql(u8, e.graph_name, GRAPH)) continue;
        if (!std.mem.eql(u8, e.label, rel)) continue;
        n += 1;
    }
    return n;
}

fn outDegree(env: *Env, src: u64, rel: []const u8) usize {
    const outgoing = env.store.getOutgoingEdgeIds(src) orelse return 0;
    var n: usize = 0;
    for (outgoing) |eid| {
        const e = env.store.getEdgePtrHydrated(eid) orelse continue;
        if (!std.mem.eql(u8, e.graph_name, GRAPH)) continue;
        if (!std.mem.eql(u8, e.label, rel)) continue;
        n += 1;
    }
    return n;
}

// Ingest K (parent)-[:PARENT_OF]->(child_i) edges via the coordinator, filling
// per-shard queues (submitNoWait) before awaiting so the 16 shard workers drain
// in parallel — the realistic from-dump bulk path. Returns edges/sec.
fn benchPopularParentParentOf(env: *Env, parent: u64, children: []const u64) !f64 {
    const coord = try group_commit.getOrStartCoordinator(env.allocator, env.adapter, GRAPH);

    const ops = try env.allocator.alloc(group_commit.ApplyOp, children.len);
    defer env.allocator.free(ops);

    const t0 = monoNs();
    for (children, 0..) |child, i| {
        ops[i] = .{ .bulk_merge_edge = .{
            .source_id = parent,
            .target_id = child,
            .rel_type = PARENT_OF,
            .props = &.{},
            .result = .{},
        } };
        try coord.submitNoWait(&ops[i]);
    }
    for (ops) |*op| _ = try coord.awaitOp(op);
    const elapsed_ns = monoNs() -| t0;

    const secs = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s);
    return @as(f64, @floatFromInt(children.len)) / secs;
}

// ===========================================================================
// DIAGNOSTIC (root-cause isolation, not a guard): same-shard vs cross-shard.
// If same-shard (no 2PC) is fast and cross-shard (per-edge 2PC) is slow, the
// cross-shard 2PC thread-pool ping-pong is the dominant cost — informs whether
// the fix is lock-batching (geode) or edge-create batching (engine).
// ===========================================================================
test "PHASE4 diag: same-engine-shard popular parent (no cross-shard 2PC)" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    group_commit.setEnabledForTest(true);

    const K: usize = 20_000;
    // Force parent AND all children onto engine shard 0 → every edge is
    // same-shard → createEdge fast path (addEdgeTxn joins the batch txn), no 2PC.
    const parent = try makeNodeOnShard(&env, "parent", 0);
    const children = try allocator.alloc(u64, K);
    defer allocator.free(children);
    for (children, 0..) |*c, i| {
        var buf: [24]u8 = undefined;
        const sid = std.fmt.bufPrint(&buf, "c{d}", .{i}) catch unreachable;
        c.* = try makeNodeOnShard(&env, sid, 0);
    }

    const eps = try benchPopularParentParentOf(&env, parent, children);
    std.debug.print(
        "\n[PHASE4-DIAG] SAME-SHARD popular parent: K={d} -> {d:.0} edges/sec (no 2PC)\n",
        .{ K, eps },
    );
    try testing.expectEqual(K, outDegree(&env, parent, PARENT_OF));
    // Diagnostic only — no throughput assertion.
}

// ===========================================================================
// HEADLINE A/B: popular-parent PARENT_OF throughput (edges/sec).
// ===========================================================================

test "PHASE4 headline: popular-parent PARENT_OF ingest throughput (edges/sec)" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    group_commit.setEnabledForTest(true);

    // One hot parent; K unique children (the from-dump PARENT_OF shape: source
    // is the genus/kingdom, target is the unique child). K kept CI-bounded but
    // large enough to expose serialization (each child is a distinct shard key
    // under tuple routing → fans out; under source_id routing → one worker).
    const K: usize = 20_000;

    const parent = try makeNode(&env, "parent");
    const children = try allocator.alloc(u64, K);
    defer allocator.free(children);
    for (children, 0..) |*c, i| {
        var buf: [24]u8 = undefined;
        const sid = std.fmt.bufPrint(&buf, "c{d}", .{i}) catch unreachable;
        c.* = try makeNode(&env, sid);
    }

    const eps = try benchPopularParentParentOf(&env, parent, children);

    std.debug.print(
        "\n[PHASE4-BENCH] popular-parent PARENT_OF: K={d} children -> {d:.0} edges/sec\n",
        .{ K, eps },
    );

    // Correctness FIRST (a fast wrong answer is worthless): every edge created,
    // exactly once, all reachable from the hot parent.
    try testing.expectEqual(K, outDegree(&env, parent, PARENT_OF));
    // Spot-check idempotency on a sample of children (full scan is O(K*degree)).
    var i: usize = 0;
    while (i < K) : (i += (K / 50) + 1) {
        try testing.expectEqual(@as(usize, 1), countEdgesTo(&env, parent, children[i], PARENT_OF));
    }

    // THROUGHPUT GUARD: must be the same ORDER as node ingest (thousands/s) and
    // demonstrably >> the 313/s pre-Phase-4 baseline. We assert a conservative
    // floor (2000/s) so the test is a real regression gate, not just a print.
    try testing.expect(eps > 2000.0);
}

// ===========================================================================
// HEADLINE A/B (mirror orientation): popular-target ACCEPTED_AS throughput.
// ACCEPTED_AS is synonym -> accepted, so the HOT node is the TARGET. This proves
// the TUPLE shardKey (not target_id alone) spreads BOTH orientations: routing on
// target_id would re-serialize this case on the hot accepted-name target.
// ===========================================================================

test "PHASE4 headline: popular-TARGET ACCEPTED_AS ingest throughput (tuple-key spreads both orientations)" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    group_commit.setEnabledForTest(true);

    const K: usize = 20_000;

    // One hot accepted name; K unique synonyms each -[:ACCEPTED_AS]-> accepted.
    const accepted = try makeNode(&env, "accepted");
    const synonyms = try allocator.alloc(u64, K);
    defer allocator.free(synonyms);
    for (synonyms, 0..) |*s, i| {
        var buf: [24]u8 = undefined;
        const sid = std.fmt.bufPrint(&buf, "syn{d}", .{i}) catch unreachable;
        s.* = try makeNode(&env, sid);
    }

    const coord = try group_commit.getOrStartCoordinator(env.allocator, env.adapter, GRAPH);
    const ops = try allocator.alloc(group_commit.ApplyOp, K);
    defer allocator.free(ops);

    const t0 = monoNs();
    for (synonyms, 0..) |syn, i| {
        ops[i] = .{
            .bulk_merge_edge = .{
                .source_id = syn, // synonym is the (unique) source
                .target_id = accepted, // accepted is the HOT target
                .rel_type = ACCEPTED_AS,
                .props = &.{},
                .result = .{},
            },
        };
        try coord.submitNoWait(&ops[i]);
    }
    for (ops) |*op| _ = try coord.awaitOp(op);
    const elapsed_ns = monoNs() -| t0;
    const secs = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s);
    const eps = @as(f64, @floatFromInt(K)) / secs;

    std.debug.print(
        "\n[PHASE4-BENCH] popular-TARGET ACCEPTED_AS: K={d} synonyms -> {d:.0} edges/sec\n",
        .{ K, eps },
    );

    // Correctness: every synonym has exactly one ACCEPTED_AS to the accepted name.
    var i: usize = 0;
    while (i < K) : (i += (K / 50) + 1) {
        try testing.expectEqual(@as(usize, 1), countEdgesTo(&env, synonyms[i], accepted, ACCEPTED_AS));
    }

    try testing.expect(eps > 2000.0);
}

// ===========================================================================
// RE-SHARD CORRECTNESS: with the new tuple shardKey, edges still resolve +
// commit correctly; cross-shard endpoints handled; ordering-independent
// (sets/counts/traversal) intact. Idempotent re-run creates no duplicates.
// ===========================================================================

test "PHASE4 reshard correctness: mixed-orientation edges commit, traverse, and re-run idempotently" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    group_commit.setEnabledForTest(true);
    const coord = try group_commit.getOrStartCoordinator(env.allocator, env.adapter, GRAPH);

    // A small hierarchy: one parent with N children (PARENT_OF, hot source) AND
    // those same children each point ACCEPTED_AS at one accepted node (hot
    // target). Both hot orientations + cross-shard endpoints in one graph.
    const N: usize = 500;
    const parent = try makeNode(&env, "P");
    const accepted = try makeNode(&env, "ACC");
    const kids = try allocator.alloc(u64, N);
    defer allocator.free(kids);
    for (kids, 0..) |*k, i| {
        var buf: [24]u8 = undefined;
        const sid = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch unreachable;
        k.* = try makeNode(&env, sid);
    }

    // Run the full edge set TWICE (idempotent MERGE must not duplicate).
    var round: usize = 0;
    while (round < 2) : (round += 1) {
        const ops = try allocator.alloc(group_commit.ApplyOp, N * 2);
        defer allocator.free(ops);
        var idx: usize = 0;
        for (kids) |k| {
            ops[idx] = .{ .bulk_merge_edge = .{ .source_id = parent, .target_id = k, .rel_type = PARENT_OF, .props = &.{}, .result = .{} } };
            idx += 1;
            ops[idx] = .{ .bulk_merge_edge = .{ .source_id = k, .target_id = accepted, .rel_type = ACCEPTED_AS, .props = &.{}, .result = .{} } };
            idx += 1;
        }
        for (ops[0..idx]) |*op| try coord.submitNoWait(op);
        for (ops[0..idx]) |*op| _ = try coord.awaitOp(op);
    }

    // Counts are exact regardless of which worker applied which edge (set
    // semantics), and the second round added nothing (idempotent).
    try testing.expectEqual(N, outDegree(&env, parent, PARENT_OF));
    var in_acc: usize = 0;
    for (kids) |k| {
        try testing.expectEqual(@as(usize, 1), countEdgesTo(&env, parent, k, PARENT_OF));
        try testing.expectEqual(@as(usize, 1), countEdgesTo(&env, k, accepted, ACCEPTED_AS));
        in_acc += 1;
    }
    try testing.expectEqual(N, in_acc);
}

// ===========================================================================
// IDEMPOTENCY under the BATCHED apply (must stay GREEN): N threads MERGE the
// SAME (a,R,b) through the coordinator → exactly ONE edge. The finer/batched
// locking must NOT admit a duplicate. This is the Phase-3 idempotency invariant
// carried forward onto the Phase-4 batched code path (the per-op direct test
// lives in test_edge_merge_shard_locked.zig; this one races the coordinator).
// ===========================================================================

const SameTupleCtx = struct {
    coord: *group_commit.ShardedCoordinator,
    a: u64,
    b: u64,
    start: *std.atomic.Value(bool),
    err: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn sameTupleWorker(ctx: *SameTupleCtx) void {
    while (!ctx.start.load(.acquire)) std.atomic.spinLoopHint();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var op = group_commit.ApplyOp{ .bulk_merge_edge = .{
            .source_id = ctx.a,
            .target_id = ctx.b,
            .rel_type = PARENT_OF,
            .props = &.{},
            .result = .{},
        } };
        _ = ctx.coord.submit(&op) catch {
            ctx.err.store(true, .release);
            return;
        };
    }
}

test "PHASE4 idempotency: concurrent same-tuple MERGE via coordinator -> exactly one edge" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    group_commit.setEnabledForTest(true);
    const coord = try group_commit.getOrStartCoordinator(env.allocator, env.adapter, GRAPH);

    const a = try makeNode(&env, "A");
    const b = try makeNode(&env, "B");

    var start = std.atomic.Value(bool).init(false);
    var ctx = SameTupleCtx{ .coord = coord, .a = a, .b = b, .start = &start };

    const num_workers = 8;
    var threads: [num_workers]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, sameTupleWorker, .{&ctx});
    start.store(true, .release);
    for (&threads) |t| t.join();

    try testing.expect(!ctx.err.load(.acquire));
    // Exactly ONE edge despite 8x100 concurrent same-tuple MERGEs racing through
    // the batched apply.
    try testing.expectEqual(@as(usize, 1), countEdgesTo(&env, a, b, PARENT_OF));
}

// ===========================================================================
// TORN-READ / consistency: one thread ingests many edges to a HOT source via
// the coordinator (batched append) while a reader repeatedly counts the hot
// source's out-edges. The reader must never see a torn/half EdgeEntry (would
// surface as a corrupt count, a crash, or a non-monotonic dip); the final count
// is exact. Reads go through the resident/engine-direct adjacency under the
// buffer-pool pin/seqlock discipline + the source shard lock.
// ===========================================================================

const TornReadCtx = struct {
    env: *Env,
    src: u64,
    stop: *std.atomic.Value(bool),
    max_seen: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    err: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn tornReader(ctx: *TornReadCtx) void {
    var last: usize = 0;
    while (!ctx.stop.load(.acquire)) {
        // acquireGraphReadLockTagged mirrors the analytical-scan reader the
        // shard-locked apply must coexist with.
        const h = graph_store.acquireGraphReadLockTagged(GRAPH, .misc);
        const n = outDegree(ctx.env, ctx.src, PARENT_OF);
        graph_store.releaseGraphLock(h);
        // The count must be monotonic non-decreasing (edges are only added). A
        // dip would mean a torn read of the block count/chain.
        if (n < last) ctx.err.store(true, .release);
        last = n;
        if (n > ctx.max_seen.load(.monotonic)) ctx.max_seen.store(n, .monotonic);
        std.atomic.spinLoopHint();
    }
}

test "PHASE4 torn-read: concurrent batched append to a hot source + repeated traverse stays consistent" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    group_commit.setEnabledForTest(true);
    const coord = try group_commit.getOrStartCoordinator(env.allocator, env.adapter, GRAPH);

    const K: usize = 5_000;
    const src = try makeNode(&env, "hot");
    const children = try allocator.alloc(u64, K);
    defer allocator.free(children);
    for (children, 0..) |*c, i| {
        var buf: [24]u8 = undefined;
        const sid = std.fmt.bufPrint(&buf, "tc{d}", .{i}) catch unreachable;
        c.* = try makeNode(&env, sid);
    }

    var stop = std.atomic.Value(bool).init(false);
    var rctx = TornReadCtx{ .env = &env, .src = src, .stop = &stop };
    const num_readers = 3;
    var readers: [num_readers]std.Thread = undefined;
    for (&readers) |*t| t.* = try std.Thread.spawn(.{}, tornReader, .{&rctx});

    // Ingest the K edges via the coordinator while readers hammer the hot source.
    const ops = try allocator.alloc(group_commit.ApplyOp, K);
    defer allocator.free(ops);
    for (children, 0..) |child, i| {
        ops[i] = .{ .bulk_merge_edge = .{ .source_id = src, .target_id = child, .rel_type = PARENT_OF, .props = &.{}, .result = .{} } };
        try coord.submitNoWait(&ops[i]);
    }
    for (ops) |*op| _ = try coord.awaitOp(op);

    stop.store(true, .release);
    for (&readers) |t| t.join();

    try testing.expect(!rctx.err.load(.acquire)); // never a non-monotonic (torn) count
    // Final count is exact, and the reader observed a prefix of it (never more).
    try testing.expectEqual(K, outDegree(&env, src, PARENT_OF));
    try testing.expect(rctx.max_seen.load(.monotonic) <= K);
}

test {
    std.testing.refAllDecls(@This());
}
