const std = @import("std");
const geode = @import("geode");
const graph_store = geode.graph_store;
const GraphStore = graph_store.GraphStore;
const PropertyValue = graph_store.PropertyValue;
const raft_apply = geode.distributed.raft_apply;
const raft_consensus = geode.distributed.raft_consensus;
const Command = raft_consensus.Command;
const cr = geode.distributed.cluster_replication;

// CANARY: REQ=REQ-GQL-RAFT-APPLY; FEATURE="Raft Apply Callback"; ASPECT=IntegrationTest; STATUS=TESTED; TEST=test_raft_apply; OWNER=distributed; UPDATED=2026-04-09

test "noop command returns empty result" {
    const allocator = std.testing.allocator;
    const result = try raft_apply.applyCommand(allocator, null, .noop, 1);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "write command returns empty result (MVP)" {
    const allocator = std.testing.allocator;
    const result = try raft_apply.applyCommand(allocator, null, .{ .write = "key=value" }, 1);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "unhandled command types return empty without error" {
    const allocator = std.testing.allocator;

    // config_change
    const r1 = try raft_apply.applyCommand(allocator, null, .{ .config_change = .{
        .change_type = .add_server,
        .server_id = 42,
        .server_endpoint = "10.0.0.1",
    } }, 1);
    defer allocator.free(r1);
    try std.testing.expectEqual(@as(usize, 0), r1.len);

    // snapshot_pointer
    const r2 = try raft_apply.applyCommand(allocator, null, .{ .snapshot_pointer = .{
        .last_included_index = 1,
        .last_included_term = 1,
        .size_bytes = 0,
        .checksum = 0,
    } }, 1);
    defer allocator.free(r2);
    try std.testing.expectEqual(@as(usize, 0), r2.len);

    // txn_prepare
    const r3 = try raft_apply.applyCommand(allocator, null, .{ .txn_prepare = .{
        .xid = 1,
        .shard_id = 0,
        .write_set = "",
        .metadata = "",
    } }, 1);
    defer allocator.free(r3);
    try std.testing.expectEqual(@as(usize, 0), r3.len);

    // txn_decide
    const r4 = try raft_apply.applyCommand(allocator, null, .{ .txn_decide = .{
        .xid = 1,
        .commit = true,
    } }, 1);
    defer allocator.free(r4);
    try std.testing.expectEqual(@as(usize, 0), r4.len);
}

test "graph_mutation create with unknown payload version is skipped (no junk node)" {
    // Slice A mixed-version safety: an opaque (no-magic) create payload must be
    // skipped fail-loud rather than minting a bogus `_raft_data` node.
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    const result = try raft_apply.applyCommand(allocator, &store, .{
        .graph_mutation = .{
            .graph = "raft_test",
            .mutation_type = .create,
            .data = "test_payload", // no GNC1/GNC2 magic
            .txn_id = null,
        },
    }, 17);
    defer allocator.free(result);

    // Skipped: empty result, no node created.
    try std.testing.expectEqual(@as(usize, 0), result.len);
    try std.testing.expectEqual(@as(usize, 0), store.nodes.count());

    // Graph was still implicitly ensured.
    try std.testing.expect(store.graphs.contains("raft_test"));
}

test "graph_mutation GNC2 edge create with store replicates 2 nodes + 1 edge" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    const la = [_][]const u8{"E"};
    const nodes = [_]cr.NodeSpec{ .{ .labels = &la, .props = &.{} }, .{ .labels = &la, .props = &.{} } };
    const edges = [_]cr.EdgeSpec{
        .{ .from = .{ .position = 0 }, .to = .{ .position = 1 }, .edge_type = "LINKS", .props = &.{} },
    };
    const payload = try cr.serializeMultiCreate(allocator, "raft_test", &nodes, &edges);
    defer allocator.free(payload);

    const result = try raft_apply.applyCommand(allocator, &store, .{ .graph_mutation = .{
        .graph = "raft_test",
        .mutation_type = .create,
        .data = payload,
        .txn_id = null,
    } }, 21);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 8), result.len);
    try std.testing.expectEqual(cr.deriveMultiNodeId(21, 0), std.mem.readInt(u64, result[0..8], .little));
    try std.testing.expectEqual(@as(usize, 2), store.nodes.count());
    try std.testing.expectEqual(@as(usize, 1), store.edges.count());
}

test "graph_mutation without store returns StoreNotAvailable" {
    const allocator = std.testing.allocator;
    const result = raft_apply.applyCommand(allocator, null, .{ .graph_mutation = .{
        .graph = "orphan",
        .mutation_type = .create,
        .data = "",
        .txn_id = null,
    } }, 1);
    try std.testing.expectError(error.StoreNotAvailable, result);
}

test "schema_change create_graph then drop_graph" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    // create
    const r1 = try raft_apply.applyCommand(allocator, &store, .{ .schema_change = .{
        .operation = .create_graph,
        .graph = "ephemeral",
        .schema = "",
    } }, 1);
    defer allocator.free(r1);
    try std.testing.expect(store.graphs.contains("ephemeral"));

    // drop
    const r2 = try raft_apply.applyCommand(allocator, &store, .{ .schema_change = .{
        .operation = .drop_graph,
        .graph = "ephemeral",
        .schema = "",
    } }, 2);
    defer allocator.free(r2);
    try std.testing.expect(!store.graphs.contains("ephemeral"));
}

test "global store set/get/reset round-trip" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(?*GraphStore, null), raft_apply.getGlobalStore());

    raft_apply.setGlobalStore(&store);
    try std.testing.expectEqual(@as(?*GraphStore, &store), raft_apply.getGlobalStore());

    raft_apply.resetGlobalStore();
    try std.testing.expectEqual(@as(?*GraphStore, null), raft_apply.getGlobalStore());
}

test "applyCallbackFn works via module-level g_store" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    raft_apply.setGlobalStore(&store);
    defer raft_apply.resetGlobalStore();

    const result = try raft_apply.applyCallbackFn(allocator, .noop, 1);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

// ---------------------------------------------------------------------------
// Slice A: GNC2 multi-id derivation + id-band collision sweep (public API).
// These mirror the in-file cluster_replication.zig tests but run under the
// `test-raft-apply` step (which roots THIS file) so the sweep is always
// exercised in the slice-A loop, not only under the full sharded `test`.
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-EDGE-CREATE; FEATURE="DistributedCluster"; ASPECT=IdBandCollisionSweep; STATUS=TESTED; TEST=test_raft_apply; OWNER=distributed; UPDATED=2026-06-09
test "GNC2 id-band sweep: GNC1 plain ids never collide with GNC2-derived ids" {
    // Conservative lower bound on the time-based id floor (graph_store encodes
    // now_ms << 16; now_ms >= 1.5e12 for any realistic deploy date).
    const time_floor: u64 = @as(u64, 1_500_000_000_000) << 16;
    const max_index: u64 = 100_000;

    var idx: u64 = 1;
    while (idx <= max_index) : (idx += 1) {
        // Every GNC2 node/edge id is in the high band (>= MULTI_ID_BASE), so it
        // can never equal a plain GNC1 id (= some raft index' < max_index).
        var k: usize = 0;
        while (k < cr.MAX_MULTI_NODES) : (k += 1) {
            const nid = cr.deriveMultiNodeId(idx, k);
            try std.testing.expect(nid >= cr.MULTI_ID_BASE);
            try std.testing.expect(nid < time_floor);
            try std.testing.expect(nid > max_index); // disjoint from plain GNC1 ids
        }
        var j: usize = 0;
        while (j < cr.MAX_MULTI_EDGES) : (j += 1) {
            const eid = cr.deriveMultiEdgeId(idx, j);
            try std.testing.expect(eid >= cr.MULTI_ID_BASE);
            try std.testing.expect(eid < time_floor);
            // Edge lane strictly above the node lane within the per-index window.
            try std.testing.expect(eid >= cr.deriveMultiNodeId(idx, cr.MAX_MULTI_NODES - 1) + 1);
        }
        // Per-index 64-wide windows are disjoint and monotone.
        try std.testing.expect(cr.deriveMultiEdgeId(idx, cr.MAX_MULTI_EDGES - 1) < cr.deriveMultiNodeId(idx + 1, 0));
    }
}

test "GNC2 two stores apply identical payload -> identical derived ids" {
    const allocator = std.testing.allocator;
    var s1 = try GraphStore.init(allocator);
    defer s1.deinit();
    var s2 = try GraphStore.init(allocator);
    defer s2.deinit();

    const la = [_][]const u8{"X"};
    const nodes = [_]cr.NodeSpec{ .{ .labels = &la, .props = &.{} }, .{ .labels = &la, .props = &.{} } };
    const edges = [_]cr.EdgeSpec{
        .{ .from = .{ .position = 0 }, .to = .{ .position = 1 }, .edge_type = "R", .props = &.{} },
    };
    const payload = try cr.serializeMultiCreate(allocator, "default", &nodes, &edges);
    defer allocator.free(payload);

    _ = try cr.applyMultiCreatePayload(allocator, &s1, payload, 99);
    _ = try cr.applyMultiCreatePayload(allocator, &s2, payload, 99);

    const e0 = cr.deriveMultiEdgeId(99, 0);
    try std.testing.expect(s1.edges.contains(e0) and s2.edges.contains(e0));
    try std.testing.expectEqual(@as(usize, 2), s1.nodes.count());
    try std.testing.expectEqual(@as(usize, 2), s2.nodes.count());
}

test "GNC2 unknown-magic apply via applyCommand creates nothing" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    // A payload with neither GNC1 nor GNC2 magic must be skipped (no junk).
    const result = try raft_apply.applyCommand(allocator, &store, .{ .graph_mutation = .{
        .graph = "g",
        .mutation_type = .create,
        .data = "ZZZZ-not-a-known-version",
        .txn_id = null,
    } }, 5);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
    try std.testing.expectEqual(@as(usize, 0), store.nodes.count());
    try std.testing.expectEqual(@as(usize, 0), store.edges.count());
}

// ---------------------------------------------------------------------------
// Slice B: GDEL DELETE / DETACH DELETE replication (leader-resolved id sets).
// These exercise the public codec + the apply-callback `.delete` branch.
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-DELETE; FEATURE="DistributedCluster"; ASPECT=DeleteRoundTrip; STATUS=TESTED; TEST=test_raft_apply; OWNER=distributed; UPDATED=2026-06-09
test "GDEL delete payload round-trips: create-then-delete converges to empty" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    // Seed a node with an incident edge (simulating a prior replicated create).
    try store.createNodeWithId(100, &.{"DelRepl"}, "default");
    try store.createNodeWithId(101, &.{"DelRepl"}, "default");
    try store.createEdgeWithId(200, 100, 101, "LINKS", "default");
    try std.testing.expectEqual(@as(usize, 2), store.nodes.count());
    try std.testing.expectEqual(@as(usize, 1), store.edges.count());

    // DETACH delete of node 100: leader resolves the incident edge id (200).
    const edge_ids = [_]u64{200};
    const node_ids = [_]u64{100};
    const payload = try cr.serializeDelete(allocator, "default", &edge_ids, &node_ids);
    defer allocator.free(payload);
    try std.testing.expect(cr.isDeletePayload(payload));

    const result = try raft_apply.applyCommand(allocator, &store, .{ .graph_mutation = .{
        .graph = "default",
        .mutation_type = .delete,
        .data = payload,
        .txn_id = null,
    } }, 7);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);

    // Edge 200 and node 100 are gone; node 101 (not targeted) remains.
    try std.testing.expect(store.getEdgePtr(200) == null);
    try std.testing.expect(store.getNodePtr(100) == null);
    try std.testing.expect(store.getNodePtr(101) != null);
    try std.testing.expectEqual(@as(usize, 1), store.nodes.count());
    try std.testing.expectEqual(@as(usize, 0), store.edges.count());
}

test "GDEL apply is idempotent: re-applying same delete payload is a clean no-op" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    try store.createNodeWithId(100, &.{"D"}, "default");
    try store.createEdgeWithId(200, 100, 100, "SELF", "default"); // self-loop incident edge

    const edge_ids = [_]u64{200};
    const node_ids = [_]u64{100};
    const payload = try cr.serializeDelete(allocator, "default", &edge_ids, &node_ids);
    defer allocator.free(payload);

    // First apply removes both; restart re-apply must NOT error and must leave 0.
    const removed1 = try cr.applyDeletePayload(allocator, &store, payload);
    try std.testing.expectEqual(@as(usize, 2), removed1);
    const removed2 = try cr.applyDeletePayload(allocator, &store, payload);
    try std.testing.expectEqual(@as(usize, 0), removed2); // already gone — no-op

    try std.testing.expectEqual(@as(usize, 0), store.nodes.count());
    try std.testing.expectEqual(@as(usize, 0), store.edges.count());
}

test "GDEL node-delete preceding its incident-edge delete still removes both (edge-first order)" {
    // Even when a node id is encoded, edges are removed FIRST so a node whose
    // incident edges are in the same payload never orphans them. (The codec
    // always writes edges before nodes.)
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    try store.createNodeWithId(1, &.{"N"}, "default");
    try store.createNodeWithId(2, &.{"N"}, "default");
    try store.createEdgeWithId(9, 1, 2, "R", "default");

    // Both nodes + the connecting edge targeted in one entry.
    const edge_ids = [_]u64{9};
    const node_ids = [_]u64{ 1, 2 };
    const payload = try cr.serializeDelete(allocator, "default", &edge_ids, &node_ids);
    defer allocator.free(payload);

    const removed = try cr.applyDeletePayload(allocator, &store, payload);
    try std.testing.expectEqual(@as(usize, 3), removed);
    try std.testing.expectEqual(@as(usize, 0), store.nodes.count());
    try std.testing.expectEqual(@as(usize, 0), store.edges.count());
}

test "GDEL unknown-magic delete via applyCommand deletes nothing" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    try store.createNodeWithId(100, &.{"Keep"}, "default");

    // A delete command whose data carries NO known magic must be skipped — it
    // must NOT touch the store.
    const result = try raft_apply.applyCommand(allocator, &store, .{ .graph_mutation = .{
        .graph = "default",
        .mutation_type = .delete,
        .data = "not-a-gdel-payload",
        .txn_id = null,
    } }, 11);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
    try std.testing.expect(store.getNodePtr(100) != null);
    try std.testing.expectEqual(@as(usize, 1), store.nodes.count());
}

test "GDEL two stores apply identical create-then-delete sequence -> identical empty state" {
    const allocator = std.testing.allocator;
    var s1 = try GraphStore.init(allocator);
    defer s1.deinit();
    var s2 = try GraphStore.init(allocator);
    defer s2.deinit();

    // Both stores get the SAME create-then-delete entry sequence (mirroring two
    // raft nodes replaying the identical committed log) and must converge alike.
    const la = [_][]const u8{"Conv"};
    const nodes = [_]cr.NodeSpec{ .{ .labels = &la, .props = &.{} }, .{ .labels = &la, .props = &.{} } };
    const edges = [_]cr.EdgeSpec{
        .{ .from = .{ .position = 0 }, .to = .{ .position = 1 }, .edge_type = "E", .props = &.{} },
    };
    const create_payload = try cr.serializeMultiCreate(allocator, "default", &nodes, &edges);
    defer allocator.free(create_payload);

    _ = try cr.applyMultiCreatePayload(allocator, &s1, create_payload, 50);
    _ = try cr.applyMultiCreatePayload(allocator, &s2, create_payload, 50);

    // Derive the ids both stores minted, then delete them via GDEL on both.
    const n0 = cr.deriveMultiNodeId(50, 0);
    const n1 = cr.deriveMultiNodeId(50, 1);
    const e0 = cr.deriveMultiEdgeId(50, 0);
    const edge_ids = [_]u64{e0};
    const node_ids = [_]u64{ n0, n1 };
    const del_payload = try cr.serializeDelete(allocator, "default", &edge_ids, &node_ids);
    defer allocator.free(del_payload);

    _ = try cr.applyDeletePayload(allocator, &s1, del_payload);
    _ = try cr.applyDeletePayload(allocator, &s2, del_payload);

    try std.testing.expectEqual(@as(usize, 0), s1.nodes.count());
    try std.testing.expectEqual(@as(usize, 0), s1.edges.count());
    try std.testing.expectEqual(@as(usize, 0), s2.nodes.count());
    try std.testing.expectEqual(@as(usize, 0), s2.edges.count());
}

test "GDEL rejects an over-cap id set at serialize time" {
    const allocator = std.testing.allocator;
    const big = try allocator.alloc(u64, cr.MAX_DELETE_IDS + 1);
    defer allocator.free(big);
    for (big, 0..) |*v, i| v.* = @intCast(i);
    try std.testing.expectError(cr.CodecError.UnsupportedPropertyType, cr.serializeDelete(allocator, "default", &.{}, big));
}

test "GDEL truncated payload is rejected, not crashed" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();
    const edge_ids = [_]u64{200};
    const node_ids = [_]u64{100};
    const full = try cr.serializeDelete(allocator, "default", &edge_ids, &node_ids);
    defer allocator.free(full);
    try std.testing.expectError(cr.CodecError.CorruptPayload, cr.applyDeletePayload(allocator, &store, full[0 .. full.len - 3]));
}

// ---------------------------------------------------------------------------
// Slice C: MERGE replication
// ---------------------------------------------------------------------------
// The NOT-MATCHED MERGE outcome rides the GNC1 .create apply path (raft-index-
// keyed id, idempotent re-apply). The MATCHED + ON MATCH SET outcome is a GMRG
// payload applied on the .merge branch (set-by-id, naturally idempotent).
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MERGE; FEATURE="DistributedCluster"; ASPECT=ApplyMergeIntegration; STATUS=TESTED; TEST=test_raft_apply; OWNER=distributed; UPDATED=2026-06-09

test "MERGE create outcome (GNC1) applies idempotently: apply twice -> 1 node" {
    // The NOT-MATCHED MERGE ships the SAME GNC1 create payload twice would imply
    // two raft entries, but a single committed entry re-applied (restart replay)
    // keys off the same raft index -> 1 node. This mirrors the create-apply
    // idempotency the MERGE create-outcome inherits.
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    const labels = [_][]const u8{"MergeRepl"};
    const props = [_]cr.Prop{.{ .key = "k", .value = .{ .Int = 1 } }};
    const payload = try cr.serializeNodeCreate(allocator, "default", &labels, &props);
    defer allocator.free(payload);

    const cmd: Command = .{ .graph_mutation = .{
        .graph = "default",
        .mutation_type = .create,
        .data = payload,
        .txn_id = null,
    } };

    const r1 = try raft_apply.applyCommand(allocator, &store, cmd, 12);
    defer allocator.free(r1);
    const r2 = try raft_apply.applyCommand(allocator, &store, cmd, 12); // restart replay
    defer allocator.free(r2);

    try std.testing.expectEqual(@as(usize, 1), store.nodes.count());
    try std.testing.expectEqual(@as(usize, 1), store.countNodesByLabel("default", "MergeRepl", null));
    try std.testing.expectEqual(@as(i64, 1), store.getNodeProperty(12, "k").?.Int);
}

test "MERGE create outcome: two stores apply same payload -> identical single node" {
    const allocator = std.testing.allocator;
    var s1 = try GraphStore.init(allocator);
    defer s1.deinit();
    var s2 = try GraphStore.init(allocator);
    defer s2.deinit();

    const labels = [_][]const u8{"MergeRepl"};
    const props = [_]cr.Prop{.{ .key = "k", .value = .{ .Int = 1 } }};
    const payload = try cr.serializeNodeCreate(allocator, "default", &labels, &props);
    defer allocator.free(payload);

    const cmd: Command = .{ .graph_mutation = .{
        .graph = "default",
        .mutation_type = .create,
        .data = payload,
        .txn_id = null,
    } };

    const a = try raft_apply.applyCommand(allocator, &s1, cmd, 21);
    defer allocator.free(a);
    const b = try raft_apply.applyCommand(allocator, &s2, cmd, 21);
    defer allocator.free(b);

    // Both stores minted the same id (= raft index) and exactly one node.
    try std.testing.expect(s1.nodes.contains(21) and s2.nodes.contains(21));
    try std.testing.expectEqual(@as(usize, 1), s1.nodes.count());
    try std.testing.expectEqual(@as(usize, 1), s2.nodes.count());
}

test "GMRG merge command applies ON MATCH SET by stable id and is idempotent" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    // A leader-matched node at a stable id.
    try store.createNodeWithId(50, &.{"MergeRepl"}, "default");
    try store.setNodeProperty(50, "v", .{ .Int = 1 });

    const props = [_]cr.Prop{.{ .key = "v", .value = .{ .Int = 2 } }};
    const payload = try cr.serializeMerge(allocator, "default", 50, &props);
    defer allocator.free(payload);

    const cmd: Command = .{ .graph_mutation = .{
        .graph = "default",
        .mutation_type = .merge,
        .data = payload,
        .txn_id = null,
    } };

    const r1 = try raft_apply.applyCommand(allocator, &store, cmd, 5);
    defer allocator.free(r1);
    const r2 = try raft_apply.applyCommand(allocator, &store, cmd, 6); // re-apply
    defer allocator.free(r2);

    try std.testing.expectEqual(@as(usize, 1), store.nodes.count());
    try std.testing.expectEqual(@as(i64, 2), store.getNodeProperty(50, "v").?.Int);
}

test "merge command with unknown payload magic is skipped (no error, no mutation)" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    const result = try raft_apply.applyCommand(allocator, &store, .{
        .graph_mutation = .{
            .graph = "default",
            .mutation_type = .merge,
            .data = "no-magic-here", // not GMRG
            .txn_id = null,
        },
    }, 9);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
    try std.testing.expectEqual(@as(usize, 0), store.nodes.count());
    // Graph is still ensured (idempotent).
    try std.testing.expect(store.graphs.contains("default"));
}

// ---------------------------------------------------------------------------
// Slice D: GUPD MATCH…SET / MATCH…REMOVE replication (the silent-divergence fix).
// The leader resolves stable ids + concrete evaluated values; .update applies the
// per-node (set, remove, add-label, remove-label) tuples deterministically.
// ---------------------------------------------------------------------------

test "GUPD update command applies SET by stable id and is idempotent (apply twice)" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    // A leader-matched node at a stable id with the seed value v=1 (SetRepl shape).
    try store.createNodeWithId(60, &.{"SetRepl"}, "default");
    try store.setNodeProperty(60, "v", .{ .Int = 1 });

    const set_props = [_]cr.Prop{.{ .key = "v", .value = .{ .Int = 2 } }};
    const updates = [_]cr.NodeUpdate{.{ .node_id = 60, .set_props = &set_props }};
    const payload = try cr.serializeUpdate(allocator, "default", &updates);
    defer allocator.free(payload);

    const cmd: Command = .{ .graph_mutation = .{
        .graph = "default",
        .mutation_type = .update,
        .data = payload,
        .txn_id = null,
    } };

    const r1 = try raft_apply.applyCommand(allocator, &store, cmd, 5);
    defer allocator.free(r1);
    const r2 = try raft_apply.applyCommand(allocator, &store, cmd, 6); // restart replay
    defer allocator.free(r2);

    try std.testing.expectEqual(@as(usize, 1), store.nodes.count());
    try std.testing.expectEqual(@as(i64, 2), store.getNodeProperty(60, "v").?.Int);
}

test "GUPD update command: remove of an absent prop is a clean no-op" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    try store.createNodeWithId(61, &.{"S"}, "default");
    try store.setNodeProperty(61, "keep", .{ .Int = 7 });

    const removes = [_][]const u8{"ghost"};
    const updates = [_]cr.NodeUpdate{.{ .node_id = 61, .remove_props = &removes }};
    const payload = try cr.serializeUpdate(allocator, "default", &updates);
    defer allocator.free(payload);

    const cmd: Command = .{ .graph_mutation = .{
        .graph = "default",
        .mutation_type = .update,
        .data = payload,
        .txn_id = null,
    } };

    const result = try raft_apply.applyCommand(allocator, &store, cmd, 8);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(i64, 7), store.getNodeProperty(61, "keep").?.Int);
    try std.testing.expect(store.getNodeProperty(61, "ghost") == null);
}

test "GUPD update command: unknown payload magic is skipped (no error, no mutation)" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    try store.createNodeWithId(62, &.{"S"}, "default");
    try store.setNodeProperty(62, "v", .{ .Int = 1 });

    const result = try raft_apply.applyCommand(allocator, &store, .{
        .graph_mutation = .{
            .graph = "default",
            .mutation_type = .update,
            .data = "no-magic-here", // not GUPD
            .txn_id = null,
        },
    }, 9);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
    // The unknown payload mutated nothing — the seed value is untouched.
    try std.testing.expectEqual(@as(i64, 1), store.getNodeProperty(62, "v").?.Int);
    try std.testing.expect(store.graphs.contains("default"));
}

test "GUPD update command: two stores apply same multi-node payload -> identical state" {
    const allocator = std.testing.allocator;
    var s1 = try GraphStore.init(allocator);
    defer s1.deinit();
    var s2 = try GraphStore.init(allocator);
    defer s2.deinit();

    inline for (.{ &s1, &s2 }) |s| {
        try s.createNodeWithId(70, &.{"M"}, "default");
        try s.createNodeWithId(71, &.{"M"}, "default");
    }

    const sp = [_]cr.Prop{.{ .key = "v", .value = .{ .Int = 3 } }};
    const updates = [_]cr.NodeUpdate{
        .{ .node_id = 70, .set_props = &sp },
        .{ .node_id = 71, .set_props = &sp },
    };
    const payload = try cr.serializeUpdate(allocator, "default", &updates);
    defer allocator.free(payload);

    const cmd: Command = .{ .graph_mutation = .{
        .graph = "default",
        .mutation_type = .update,
        .data = payload,
        .txn_id = null,
    } };

    const r1 = try raft_apply.applyCommand(allocator, &s1, cmd, 11);
    defer allocator.free(r1);
    const r2 = try raft_apply.applyCommand(allocator, &s2, cmd, 11);
    defer allocator.free(r2);

    try std.testing.expectEqual(@as(i64, 3), s1.getNodeProperty(70, "v").?.Int);
    try std.testing.expectEqual(@as(i64, 3), s1.getNodeProperty(71, "v").?.Int);
    try std.testing.expectEqual(@as(i64, 3), s2.getNodeProperty(70, "v").?.Int);
    try std.testing.expectEqual(@as(i64, 3), s2.getNodeProperty(71, "v").?.Int);
}

// ---------------------------------------------------------------------------
// MATCH…CREATE edge replication: a zero-node GNC2 payload whose edge endpoints
// reference PRE-EXISTING nodes by stable id (.absolute_id). Pins the apply-side
// contract the leader slice for `MATCH (a),(b) CREATE (a)-[:R]->(b)` depends on.
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MATCH-CREATE; FEATURE="DistributedCluster"; ASPECT=ApplyAbsoluteIdEdge; STATUS=TESTED; TEST=tests/test_raft_apply.zig; OWNER=distributed; UPDATED=2026-06-10
test "GNC2: zero-node payload with absolute_id endpoints creates edge between pre-existing nodes, idempotently" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    // Pre-create two nodes at stable ids (leader-matched endpoints).
    const src_id: u64 = 300;
    const dst_id: u64 = 301;
    try store.createNodeWithId(src_id, &.{"MatchCreate"}, "default");
    try store.createNodeWithId(dst_id, &.{"MatchCreate"}, "default");
    try std.testing.expectEqual(@as(usize, 0), store.edges.count());

    const edge_specs = [_]cr.EdgeSpec{.{
        .from = .{ .absolute_id = src_id },
        .to = .{ .absolute_id = dst_id },
        .edge_type = "MCL",
        .props = &.{},
    }};
    const payload = try cr.serializeMultiCreate(allocator, "default", &.{}, &edge_specs);
    defer allocator.free(payload);

    const n1 = try cr.applyMultiCreatePayload(allocator, &store, payload, 4242);
    try std.testing.expect(n1 >= 1);

    // Exactly one MCL edge exists, from src_id to dst_id, at the derived id.
    const edge_id = cr.deriveMultiEdgeId(4242, 0);
    try std.testing.expectEqual(@as(usize, 1), store.edges.count());
    const edge = store.getEdgePtr(edge_id) orelse return error.EdgeNotFound;
    try std.testing.expectEqual(src_id, edge.from_id);
    try std.testing.expectEqual(dst_id, edge.to_id);
    try std.testing.expectEqualStrings("MCL", edge.label);

    // Re-apply (restart replay) must be a no-op: still exactly one edge,
    // and the pre-existing endpoint nodes are untouched.
    _ = try cr.applyMultiCreatePayload(allocator, &store, payload, 4242);
    try std.testing.expectEqual(@as(usize, 1), store.edges.count());
    try std.testing.expectEqual(@as(usize, 2), store.nodes.count());
    try std.testing.expect(store.getNodePtr(src_id) != null);
    try std.testing.expect(store.getNodePtr(dst_id) != null);
}
