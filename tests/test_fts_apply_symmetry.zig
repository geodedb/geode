// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// CANARY: REQ=REQ-DIST-CLUSTER-FTS-APPLY-SYMMETRY; FEATURE="DistributedCluster"; ASPECT=FtsApplySymmetry; STATUS=TESTED; TEST=tests/test_fts_apply_symmetry.zig; OWNER=distributed; UPDATED=2026-06-10
//
//! Cluster divergence hole (2026-06-10 audit, slice 3): the EXECUTOR maintains
//! every covering fulltext index on node create / SET / delete via
//! `fts_index_ops.maintainFulltextOnWrite` (src/execution/property_mutation.zig
//! + crud_operations.zig), but the RAFT APPLY paths in
//! src/distributed/cluster_replication.zig (GNC1/GNC2 create, GMRG merge, GUPD
//! update) call the store mutators (`createNodeWithId`/`setNodeProperty`/...)
//! DIRECTLY — so a FOLLOWER applying committed entries never updates its FTS
//! index and follower `CALL geode.fts.search` silently diverges from the
//! leader.
//!
//! These tests pin the SYMMETRY contract: applying a replicated payload to a
//! store must leave every covering fulltext index in the same state the
//! executor path would have. The apply-side FTS maintenance hook (Task 13,
//! `fts_index_ops.registerFtsApplyHook`) turns them green; the harness
//! registers it in `init` exactly as the server does at startup. The
//! maintenance plumbing (`maintainFulltextOnWrite`) resolves the
//! adapter/store through the same process-global registry the executor uses,
//! so an in-process apply has everything it needs.
//!
//! NOTE on the GUPD stale-term assertion (amended in Task 13): the original
//! red test expected the OLD term to be GONE after a replicated SET, citing
//! "the executor re-runs delete-then-index". That premise was factually
//! wrong: the executor's SET chokepoint deliberately uses op `.upsert` (NOT
//! delete-then-reindex) because fts-storage tombstones are PERMANENT per
//! doc_id — `deleteNode` adds the id to the engine's `all_tombstones` set and
//! a later `indexDocument` never clears it, so delete+reindex of the same
//! node id hides the node from search entirely (the 2026-06-07 "zero
//! results" bug; see src/execution/property_mutation.zig:326 and
//! docs/bugs/2026-06-07-fts-search-returns-zero-results-at-runtime.md).
//! SYMMETRY therefore means the follower must match the executor's ACTUAL
//! semantics. Since SONNY-6421 (executor) and SONNY-6433 (apply) both drop
//! the old term without delete-then-reindex: replacing indexed text queues
//! the covering index for a rebuild from the store at the end of the
//! statement / applied entry. The test pins the new term searchable and the
//! old one gone on the apply path.
//!
//! Harness mirrors tests/test_fts_e2e.zig (real store + real parser + real
//! executor + real fts-storage engine — no mocks). Unique tokens ("zraven",
//! "zosprey") guarantee hits can only come from the payload-applied writes.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const cr = geode.distributed.cluster_replication;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Harness mirrors tests/test_fts_e2e.zig.
const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        // Wire the raft apply + snapshot-install seams to the executor's FTS
        // live-maintenance — the same one-time registration the server does
        // at startup (src/server/main.zig). Idempotent across tests.
        execution.fts_index_ops.registerFtsApplyHook();

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// Run a statement whose result we don't inspect.
    pub fn run(self: *Harness, query: []const u8) !void {
        var r = try self.runQuery(query);
        r.deinit(self.arena.allocator());
    }

    /// Number of `CALL geode.fts.search` hits for `term` in `index`.
    pub fn searchCount(self: *Harness, index: []const u8, term: []const u8) !usize {
        const aa = self.arena.allocator();
        const gql = try std.fmt.allocPrint(aa, "CALL geode.fts.search('{s}', '{s}')", .{ index, term });
        var r = try self.runQuery(gql);
        defer r.deinit(aa);
        return r.rows.len;
    }

    /// BM25 score (column 1, Double) of the TOP `CALL geode.fts.search` hit
    /// for `term` in `index`. Errors if there are no hits.
    pub fn searchTopScore(self: *Harness, index: []const u8, term: []const u8) !f64 {
        const aa = self.arena.allocator();
        const gql = try std.fmt.allocPrint(aa, "CALL geode.fts.search('{s}', '{s}')", .{ index, term });
        var r = try self.runQuery(gql);
        defer r.deinit(aa);
        if (r.rows.len == 0) return error.NoSearchHits;
        return r.rows[0][1].Double;
    }
};

test "raft GNC2 create apply maintains the fulltext index like the executor path" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const a = testing.allocator;

    // 1. Fulltext index on an EMPTY graph: backfill indexes nothing, so every
    //    hit below can only come from write-path maintenance.
    try h.run("CREATE INDEX doc_idx FOR (d:Doc) ON (d.body) USING fulltext");

    // 2. SANITY (executor path): a GQL CREATE is indexed by the live hook.
    try h.run("CREATE (:Doc {body: 'executor zheron doc'})");
    try testing.expectEqual(@as(usize, 1), try h.searchCount("doc_idx", "zheron"));

    // 3. FOLLOWER apply: a GNC2 multi-create payload carrying a :Doc node whose
    //    body holds the unique token "zraven" — the exact path a follower runs
    //    for a committed replicated CREATE.
    const store = graph_store.getGlobalStore(a);
    const labels = [_][]const u8{"Doc"};
    const props = [_]cr.Prop{.{ .key = "body", .value = .{ .String = "replicated zraven doc" } }};
    const nodes = [_]cr.NodeSpec{.{ .labels = &labels, .props = &props }};
    const payload = try cr.serializeMultiCreate(a, graph_store.DEFAULT_GRAPH_NAME, &nodes, &.{});
    defer a.free(payload);
    _ = try cr.applyMultiCreatePayload(a, store, payload, 9001);

    // Setup assertion (NOT the red): the node + property landed in the store.
    const nid = cr.deriveMultiNodeId(9001, 0);
    const body = store.getNodeProperty(nid, "body") orelse return error.AppliedNodeMissingBody;
    try testing.expectEqualStrings("replicated zraven doc", body.String);

    // 4. SYMMETRY CONTRACT (red before Task 13): the applied node must be
    //    searchable exactly as if the executor had created it.
    try testing.expectEqual(@as(usize, 1), try h.searchCount("doc_idx", "zraven"));

    // 5. RESTART-REPLAY DEDUP PIN: re-apply the SAME payload at the SAME raft
    //    index — exactly what a restarted follower does when replaying its
    //    committed log on top of the persisted store. The create is tolerated
    //    as NodeAlreadyExists and the FTS hook must NOT re-fire: the engine is
    //    append-only with no doc dedup, so a second upsert duplicates the
    //    node's postings. Search DEDUPS rows per doc_id (count stays 1), but
    //    the duplicated term frequency inflates the restarted follower's BM25
    //    score vs non-restarted peers — so the pin asserts BOTH the row count
    //    AND that the score is bit-identical to the pre-replay score.
    const score_before_replay = try h.searchTopScore("doc_idx", "zraven");
    _ = try cr.applyMultiCreatePayload(a, store, payload, 9001);
    try testing.expectEqual(@as(usize, 1), try h.searchCount("doc_idx", "zraven"));
    try testing.expectEqual(score_before_replay, try h.searchTopScore("doc_idx", "zraven"));
}

test "raft GUPD update apply maintains the fulltext index (new term indexed, old term dropped like the executor)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const a = testing.allocator;

    try h.run("CREATE INDEX doc_idx FOR (d:Doc) ON (d.body) USING fulltext");

    // Executor-created doc, indexed by the live hook (sanity-proven).
    try h.run("CREATE (:Doc {body: 'stale zraven token'})");
    try testing.expectEqual(@as(usize, 1), try h.searchCount("doc_idx", "zraven"));

    // FOLLOWER apply: a GUPD payload SETting body on that node by stable id —
    // the exact path a follower runs for a committed replicated MATCH…SET.
    const store = graph_store.getGlobalStore(a);
    const ids = store.getNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, "Doc") orelse return error.DocNodeMissing;
    try testing.expectEqual(@as(usize, 1), ids.len);
    const nid = ids[0];

    const set_props = [_]cr.Prop{.{ .key = "body", .value = .{ .String = "fresh zosprey token" } }};
    const updates = [_]cr.NodeUpdate{.{ .node_id = nid, .set_props = &set_props }};
    const payload = try cr.serializeUpdate(a, graph_store.DEFAULT_GRAPH_NAME, &updates);
    defer a.free(payload);
    _ = try cr.applyUpdatePayload(a, store, payload);

    // Setup assertion (NOT the red): the store property WAS overwritten.
    const body = store.getNodeProperty(nid, "body") orelse return error.UpdatedNodeMissingBody;
    try testing.expectEqualStrings("fresh zosprey token", body.String);

    // SYMMETRY CONTRACT (red before Task 13): the NEW term must be searchable,
    // exactly as it would be after an executor SET (which fires op `.upsert`).
    try testing.expectEqual(@as(usize, 1), try h.searchCount("doc_idx", "zosprey"));
    // EXECUTOR PARITY: the OLD term is no longer found. The executor SET
    // chokepoint queues the covering index for a statement-end rebuild when
    // it replaces indexed text (SONNY-6421), and the apply path now does the
    // same at the end of the applied entry (SONNY-6433); neither deletes and
    // re-indexes the node (fts-storage tombstones are permanent per doc_id).
    try testing.expectEqual(@as(usize, 0), try h.searchCount("doc_idx", "zraven"));
}

// NOTE (concurrency precondition): the rebuild path exercised here
// (rebuildAllFulltextIndexes) requires NO concurrent searches —
// installSnapshotData has NO production caller yet (reportSnapshot wiring
// pending); before wiring InstallSnapshot into raft_consensus, the
// facade/engine drop-recreate must be made safe against concurrent
// QUIC-worker searches (unlocked fts_facades map + engine deinit race).
test "raft snapshot install rebuilds fulltext indexes from the restored store" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const a = testing.allocator;
    const snap_mgr = geode.distributed.raft_snapshot_manager;

    try h.run("CREATE INDEX doc_idx FOR (d:Doc) ON (d.body) USING fulltext");

    // Executor-created doc, live-indexed (sanity-proven).
    try h.run("CREATE (:Doc {body: 'snapshot zsnaptok doc'})");
    try testing.expectEqual(@as(usize, 1), try h.searchCount("doc_idx", "zsnaptok"));

    // Serialize a snapshot CONTAINING the doc.
    const store = graph_store.getGlobalStore(a);
    const snap = try snap_mgr.createSnapshotData(a, store);
    defer a.free(snap.data);

    // Executor-DELETE the doc: live maintenance fires `.delete`, which
    // PERMANENTLY tombstones the node id in the fts engine.
    try h.run("MATCH (d:Doc) DETACH DELETE d");
    try testing.expectEqual(@as(usize, 0), try h.searchCount("doc_idx", "zsnaptok"));

    // Install the snapshot: clearNodes + *NoSave recreate — which never touch
    // FTS. The node comes back under its ORIGINAL id, so WITHOUT the rebuild
    // hook the engine's tombstone keeps it invisible forever (red before
    // Task 13). The rebuild drops + recreates the engine (fresh, tombstone-
    // free) and re-backfills from the restored store.
    try snap_mgr.installSnapshotData(a, store, snap.data, snap.checksum);

    // Setup assertion (NOT the contract): the store row was restored.
    const ids = store.getNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, "Doc") orelse return error.RestoredNodeMissing;
    try testing.expectEqual(@as(usize, 1), ids.len);

    // SYMMETRY CONTRACT: the restored doc must be searchable again.
    try testing.expectEqual(@as(usize, 1), try h.searchCount("doc_idx", "zsnaptok"));
}
