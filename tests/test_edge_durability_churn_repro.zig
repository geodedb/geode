// CANARY: REQ=REQ-DIST-EDGE-DURABILITY-CHURN; FEATURE="DistributedCluster"; ASPECT=EdgeReApplyIdempotency; STATUS=TESTED; TEST=test_edge_durability_churn_repro; OWNER=distributed; UPDATED=2026-06-12
//
// Regression tests for the edge data-integrity defect surfaced on k8s under
// churn: an edge is unqueryable on all replicas after a kill/rejoin round
// (error.EdgeSlotMappingMissing, wire 58000), while the nodes survive.
//
// Closure log: docs/bugs (EdgeSlotMappingMissing under churn).
//
// ROOT CAUSE (verified by the RED runs below):
//   `createEdgeWithIdInternal` (src/graph_store.zig) mints the durable
//   storage-adapter edge slot (`vt.createEdgeFn`) BEFORE the in-memory
//   idempotency check (`if (self.edges.contains(edge_id)) return
//   error.EdgeAlreadyExists;`). On an idempotent Raft re-apply (the edge
//   already lives in the persisted store), the early return leaves an ORPHAN
//   physical edge slot in durable storage with NO __geode_internal_edge_id
//   property and NO IdMap entry. Hydration (`loadOneGraphFromAdapter`) reverse-
//   maps each scanned physical edge slot via the persisted public id; the
//   orphan has none, so it is SKIPPED (skipped_edge_mappings++) and stays in the
//   physical adjacency with no mapping. The read path
//   (planned_read_runtime materializeEdge) then does
//   `id_map.edgeUuid(slot) orelse return error.EdgeSlotMappingMissing`.
//
//   The node path (`createNodeWithIdInternal`) does the existence check FIRST,
//   so it never leaks an orphan node slot — which is exactly why nodes survive
//   churn and edges do not.
//
// POST-FIX CONTRACT (what these tests pin GREEN once the fix lands):
//   1. createEdgeWithIdInternal checks existence BEFORE minting the adapter slot
//      (mirroring the node path), so N idempotent re-applies mint exactly ONE
//      durable edge slot — durable_edges == 1, zero orphan slots, and the edge
//      is resolvable in BOTH directions (forward edgeSlot + reverse edgeUuid)
//      after restart/rehydrate.
//   2. Hydration self-heals an already-corrupted PVC: an orphan physical edge
//      slot (no __geode_internal_edge_id, not canonical for its public id) is
//      DELETED on rehydrate rather than skipped, so already-damaged stores
//      converge to durable_edges == 1 and the canonical edge still queries.
//
// These assertions are RED on the unfixed build (durable_edges grows by one per
// re-apply; orphan slots > 0 after restart) and GREEN after the fix.

const std = @import("std");
const geode = @import("geode");
const graph_store = geode.graph_store;
const GraphStore = graph_store.GraphStore;
const cluster_replication = geode.distributed.cluster_replication;
const NodeSpec = cluster_replication.NodeSpec;
const EdgeSpec = cluster_replication.EdgeSpec;

fn dataDirFor(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

/// Scan every PHYSICAL outgoing edge slot the storage adjacency yields and
/// reverse-map each slot -> public UUID via the rehydrated IdMap — exactly the
/// read-path lookup `planned_read_runtime.materializeEdge` performs. Returns the
/// total physical slots seen and how many have NO IdMap mapping (each unmapped
/// slot is one `error.EdgeSlotMappingMissing` on the planned read path).
const SlotScan = struct { physical: usize, unmapped: usize };

fn scanEdgeSlots(store: *GraphStore, graph: []const u8, a: std.mem.Allocator) !SlotScan {
    const adapter = graph_store.getGlobalAdapter().?;
    const id_map = store.getIdMap(graph) orelse return error.IdMapNotLoaded;
    const scan = try adapter.scanAllNodes(graph, a);
    defer a.free(scan);

    var result = SlotScan{ .physical = 0, .unmapped = 0 };
    for (scan) |entry| {
        var out = try adapter.iterateOutgoingEdges(graph, entry.slot_id, a);
        defer out.deinit();
        while (try out.next()) |edge_entry| {
            result.physical += 1;
            if (id_map.edgeUuid(edge_entry.edge_id) == null) {
                result.unmapped += 1;
                std.debug.print("  [read-path] ORPHAN physical edge slot {d} has NO IdMap mapping -> EdgeSlotMappingMissing\n", .{edge_entry.edge_id});
            }
        }
    }
    return result;
}

// ===========================================================================
// Test 1 — idempotent re-apply must NOT orphan a durable edge slot.
// ===========================================================================
test "REGRESSION: N idempotent edge re-applies + restart leave exactly one durable edge, zero orphan slots, edge resolvable both directions" {
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try dataDirFor(a, &tmp);
    defer a.free(data_dir);

    const la = [_][]const u8{"BW"};
    const nodes = [_]NodeSpec{
        .{ .labels = &la, .props = &.{} },
        .{ .labels = &la, .props = &.{} },
    };
    const edges = [_]EdgeSpec{
        .{ .from = .{ .position = 0 }, .to = .{ .position = 1 }, .edge_type = "BWL", .props = &.{} },
    };
    const payload = try cluster_replication.serializeMultiCreate(a, "default", &nodes, &edges);
    defer a.free(payload);

    const raft_index: u64 = 7;
    // The canonical replicated edge id is deterministic from the committed raft
    // index — identical on every replica (Log Matching Property), which is what
    // makes the persisted store the dedup oracle across restart.
    const canonical_edge_id = cluster_replication.deriveMultiEdgeId(raft_index, 0);

    // ---- Boot 1: REAL engine-backed adapter + store. Apply once, then RE-APPLY
    // the SAME committed entry N times (one churn round = N restarts each
    // replaying the committed log on top of the persisted store). ----
    //
    // COLD-OPEN NOTE: this suite models a k8s CHURN kill (pod killed after the
    // committed writes were checkpointed durably). We therefore end boot1 with
    // `checkpointAll()` (durable engine pages) + `deinitGlobalStoreForTestCrash`
    // (NO clean-shutdown fast-restart snapshot). That is deliberate: a clean
    // `deinitGlobalStore` would write the loop2 / IdMap snapshots, and boot2
    // would then take the O(1) `snapshot_served` fast path in
    // `loadOneGraphFromAdapterFull` — which restores the IdMap + counters but
    // (by design, hydrate-on-miss) leaves `store.nodes`/`store.edges` EMPTY and
    // SKIPS the engine scan. This suite asserts on resident state AND (test 2)
    // on the scan-driven orphan self-heal, so it must reopen via the full engine
    // rebuild path. A checkpoint-then-crash is the exact posture that forces it
    // (no snapshot => scan-rebuild), and is the faithful model of the churn
    // restart under test.
    {
        const store = try graph_store.initGlobalStore(a, data_dir);
        defer graph_store.deinitGlobalStoreForTestCrash();
        const adapter = graph_store.getGlobalAdapter().?;

        _ = try cluster_replication.applyMultiCreatePayload(a, store, payload, raft_index);

        var i: usize = 0;
        while (i < 4) : (i += 1) {
            _ = try cluster_replication.applyMultiCreatePayload(a, store, payload, raft_index);
        }

        try adapter.checkpointAll();
        const durable_after = try adapter.edgeCount("default");
        std.debug.print("[test1 boot1] after 5 applies: mem_edges={d} durable_edges={d}\n", .{ store.edges.count(), durable_after });

        // Post-fix contract: 5 idempotent applies mint exactly ONE durable slot.
        // RED on the unfixed build: durable_after == 5 (4 orphan slots).
        if (durable_after != 1) {
            std.debug.print("[test1 boot1] FAIL: expected exactly 1 durable edge slot after 5 idempotent applies, found {d} ({d} orphan slot(s))\n", .{ durable_after, durable_after - 1 });
        }
        try std.testing.expectEqual(@as(u64, 1), durable_after);
    }

    // ---- Boot 2: fresh-process posture — re-open the SAME data dir, re-hydrate,
    // and verify the edge is intact and resolvable both directions. ----
    {
        const store = try graph_store.initGlobalStore(a, data_dir);
        defer graph_store.deinitGlobalStore();

        try store.loadFromFile();
        // EARLY-READY (H3): loadFromFile defers the per-graph loop1/loop2
        // build; force it like the read-path chokepoints do on first access.
        store.ensureGraphHydrated("default");
        std.debug.print("[test1 boot2] post-load: mem_nodes={d} mem_edges={d}\n", .{ store.nodes.count(), store.edges.count() });

        try std.testing.expectEqual(@as(usize, 2), store.nodes.count());
        // Exactly one logical edge survives rehydrate.
        try std.testing.expectEqual(@as(usize, 1), store.edges.count());

        // No orphan physical slot remains: every physical edge slot reverse-maps.
        const slots = try scanEdgeSlots(store, "default", a);
        std.debug.print("[test1 boot2] physical_edges_scanned={d} unmapped_slots={d}\n", .{ slots.physical, slots.unmapped });
        if (slots.unmapped != 0) {
            std.debug.print("[test1 boot2] FAIL: {d} orphan physical edge slot(s) survive rehydrate -> EdgeSlotMappingMissing on read\n", .{slots.unmapped});
        }
        try std.testing.expectEqual(@as(usize, 0), slots.unmapped);
        try std.testing.expectEqual(@as(usize, 1), slots.physical);

        // Forward AND reverse resolution of the canonical edge both succeed.
        const id_map = store.getIdMap("default") orelse return error.IdMapNotLoaded;
        const slot = id_map.edgeSlot(@as(u128, canonical_edge_id)) orelse {
            std.debug.print("[test1 boot2] FAIL: forward edgeSlot({d}) missing -> edge unqueryable\n", .{canonical_edge_id});
            return error.EdgeSlotMappingMissing;
        };
        const back = id_map.edgeUuid(slot) orelse {
            std.debug.print("[test1 boot2] FAIL: reverse edgeUuid({d}) missing -> EdgeSlotMappingMissing\n", .{slot});
            return error.EdgeSlotMappingMissing;
        };
        try std.testing.expectEqual(@as(u128, canonical_edge_id), back);
    }
}

// ===========================================================================
// Test 2 — hydration self-heal of an ALREADY-corrupted store.
// ===========================================================================
//
// Boot 1 manufactures the EXACT on-disk damage the OLD buggy binary left on a
// PVC, but does so by INJECTING orphan physical edge slots DIRECTLY at the
// storage-adapter layer (`adapter.createEdge`, the same path `vt.createEdgeFn`
// wraps) — deliberately BYPASSING the now-fixed `createEdgeWithIdInternal`. The
// canonical edge is created normally first (so it carries a real
// `__geode_internal_edge_id` + IdMap entry); then we mint N EXTRA physical slots
// between the same endpoints WITHOUT a public-id property — precisely the shape
// the pre-fix re-apply ordering bug left behind (an adapter slot with no
// `__geode_internal_edge_id` and no legacy mapping). We MUST inject directly:
// now that Part 1 of the fix runs the existence check before minting the slot,
// re-applying the committed entry no longer produces any orphan, so driving the
// re-apply path would corrupt nothing and the Part 2 self-heal deletion logic
// would never be exercised. Boot 2 re-opens and re-hydrates; the post-fix
// hydration repair must DELETE the orphan slots instead of skipping them, so an
// already-damaged store converges to a single durable edge and the canonical
// edge still queries.
test "REGRESSION: hydration self-heals an already-corrupted store — orphan edge slots are deleted, canonical edge still queries" {
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try dataDirFor(a, &tmp);
    defer a.free(data_dir);

    const la = [_][]const u8{"BW"};
    const nodes = [_]NodeSpec{
        .{ .labels = &la, .props = &.{} },
        .{ .labels = &la, .props = &.{} },
    };
    const edges = [_]EdgeSpec{
        .{ .from = .{ .position = 0 }, .to = .{ .position = 1 }, .edge_type = "BWL", .props = &.{} },
    };
    const payload = try cluster_replication.serializeMultiCreate(a, "default", &nodes, &edges);
    defer a.free(payload);

    const raft_index: u64 = 9;
    const canonical_edge_id = cluster_replication.deriveMultiEdgeId(raft_index, 0);
    // Endpoint PUBLIC node ids are deterministic from the raft index (same
    // derivation applyMultiCreatePayload uses), so we can resolve their durable
    // SLOT ids from the rehydrated IdMap to address the adapter directly.
    const from_node_id = cluster_replication.deriveMultiNodeId(raft_index, 0);
    const to_node_id = cluster_replication.deriveMultiNodeId(raft_index, 1);

    // Number of orphan physical edge slots the old buggy binary would have left
    // (one per idempotent re-apply in a churn round).
    const orphan_count: usize = 3;

    // ---- Boot 1: create the canonical edge normally, then INJECT orphan slots
    // directly at the adapter layer (bypassing the fixed createEdgeWithIdInternal)
    // to reproduce the exact on-disk damage of an old buggy binary. ----
    {
        const store = try graph_store.initGlobalStore(a, data_dir);
        // Checkpoint-then-crash (see the COLD-OPEN NOTE on test 1): forces boot2
        // to reopen via the full engine scan so the orphan self-heal runs.
        defer graph_store.deinitGlobalStoreForTestCrash();
        const adapter = graph_store.getGlobalAdapter().?;

        // Canonical create: goes through the fixed path, so it carries a real
        // __geode_internal_edge_id property and an IdMap entry — exactly ONE
        // healthy durable slot.
        _ = try cluster_replication.applyMultiCreatePayload(a, store, payload, raft_index);

        // Resolve the endpoint SLOT ids the adapter addresses (the engine's
        // addEdge operates on slot ids, NOT public ids).
        const id_map = store.getIdMap("default") orelse return error.IdMapNotLoaded;
        const from_slot = id_map.nodeSlot(@as(u128, from_node_id)) orelse {
            std.debug.print("[test2 boot1] FAIL: could not resolve from-node slot for public id {d}\n", .{from_node_id});
            return error.NodeSlotMappingMissing;
        };
        const to_slot = id_map.nodeSlot(@as(u128, to_node_id)) orelse {
            std.debug.print("[test2 boot1] FAIL: could not resolve to-node slot for public id {d}\n", .{to_node_id});
            return error.NodeSlotMappingMissing;
        };

        // Mint N EXTRA physical edge slots between the same endpoints, WITHOUT
        // ever calling persistEdgePublicId / inserting an IdMap entry — the
        // adapter slot exists in the durable adjacency but has no
        // __geode_internal_edge_id property. This is byte-for-byte the orphan
        // shape the pre-fix createEdgeWithIdInternal ordering bug produced on
        // every idempotent Raft re-apply.
        var j: usize = 0;
        while (j < orphan_count) : (j += 1) {
            const orphan_slot = try adapter.createEdge("default", from_slot, to_slot, "BWL");
            std.debug.print("[test2 boot1] injected orphan physical edge slot {d} (no __geode_internal_edge_id)\n", .{orphan_slot});
        }

        try adapter.checkpointAll();
        const durable = try adapter.edgeCount("default");
        std.debug.print("[test2 boot1] corrupted store: durable_edges={d} (1 canonical + {d} injected orphan slots)\n", .{ durable, orphan_count });
        // Precondition: the injection actually produced the damage we intend to
        // self-heal. If this fails, Boot 2 would pass trivially and never exercise
        // the deletion path — defeating the whole point of this test.
        if (durable != 1 + @as(u64, orphan_count)) {
            std.debug.print("[test2 boot1] FAIL: expected {d} durable slots after injecting {d} orphans, found {d} — corruption setup did not take\n", .{ 1 + @as(u64, orphan_count), orphan_count, durable });
        }
        try std.testing.expectEqual(@as(u64, 1 + @as(u64, orphan_count)), durable);
    }

    // ---- Boot 2: rehydrate. The fix's hydration repair must delete the orphan
    // slots so the store converges to exactly one durable edge. ----
    {
        const store = try graph_store.initGlobalStore(a, data_dir);
        defer graph_store.deinitGlobalStore();
        const adapter = graph_store.getGlobalAdapter().?;

        try store.loadFromFile();
        // EARLY-READY (H3): force the deferred loop1/loop2 build (see test 1).
        store.ensureGraphHydrated("default");
        std.debug.print("[test2 boot2] post-load: mem_nodes={d} mem_edges={d}\n", .{ store.nodes.count(), store.edges.count() });

        try std.testing.expectEqual(@as(usize, 2), store.nodes.count());
        try std.testing.expectEqual(@as(usize, 1), store.edges.count());

        // Orphan slots must be REPAIRED (deleted), not merely skipped.
        const slots = try scanEdgeSlots(store, "default", a);
        std.debug.print("[test2 boot2] physical_edges_scanned={d} unmapped_slots={d}\n", .{ slots.physical, slots.unmapped });
        if (slots.unmapped != 0) {
            std.debug.print("[test2 boot2] FAIL: {d} orphan physical edge slot(s) NOT repaired on rehydrate\n", .{slots.unmapped});
        }
        try std.testing.expectEqual(@as(usize, 0), slots.unmapped);
        try std.testing.expectEqual(@as(usize, 1), slots.physical);

        // Durable storage itself converged to one edge (orphans physically gone).
        const durable_after = try adapter.edgeCount("default");
        std.debug.print("[test2 boot2] durable_edges after self-heal={d}\n", .{durable_after});
        if (durable_after != 1) {
            std.debug.print("[test2 boot2] FAIL: durable storage still carries {d} edge slot(s) after self-heal (expected 1)\n", .{durable_after});
        }
        try std.testing.expectEqual(@as(u64, 1), durable_after);

        // The canonical edge still resolves both directions after the heal.
        const id_map = store.getIdMap("default") orelse return error.IdMapNotLoaded;
        const slot = id_map.edgeSlot(@as(u128, canonical_edge_id)) orelse return error.EdgeSlotMappingMissing;
        const back = id_map.edgeUuid(slot) orelse return error.EdgeSlotMappingMissing;
        try std.testing.expectEqual(@as(u128, canonical_edge_id), back);
    }
}

// ===========================================================================
// Test 3 — GUARD: the fix must not over-dedup / over-delete distinct edges.
// ===========================================================================
//
// GREEN TODAY and must keep passing after the fix. Two genuinely distinct
// committed edges (different raft indices) between distinct node pairs must each
// survive as their own durable edge across restart. This is the over-dedup /
// over-delete guard: it applies each distinct committed entry EXACTLY ONCE (no
// churn re-apply, so the orphan-slot bug is not triggered here), which means it
// passes on the unfixed build today — and pins the fix to "delete only orphan
// slots", never a legitimate parallel edge. If the fix collapses or deletes a
// distinct edge, this turns RED.
test "GUARD: two distinct committed edges survive restart as two durable edges (no over-dedup/over-delete)" {
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try dataDirFor(a, &tmp);
    defer a.free(data_dir);

    const la = [_][]const u8{"BW"};
    const nodes = [_]NodeSpec{
        .{ .labels = &la, .props = &.{} },
        .{ .labels = &la, .props = &.{} },
    };
    const edges = [_]EdgeSpec{
        .{ .from = .{ .position = 0 }, .to = .{ .position = 1 }, .edge_type = "BWL", .props = &.{} },
    };
    const payload = try cluster_replication.serializeMultiCreate(a, "default", &nodes, &edges);
    defer a.free(payload);

    // Two SEPARATE committed entries at DIFFERENT raft indices -> two distinct
    // edge ids. Node ids derive from the raft index, so each entry creates its
    // own node pair too; the point is that two distinct committed edges both
    // survive (the fix must not over-delete a legitimate edge).
    const idx_a: u64 = 11;
    const idx_b: u64 = 12;
    const edge_id_a = cluster_replication.deriveMultiEdgeId(idx_a, 0);
    const edge_id_b = cluster_replication.deriveMultiEdgeId(idx_b, 0);
    try std.testing.expect(edge_id_a != edge_id_b);

    {
        const store = try graph_store.initGlobalStore(a, data_dir);
        // Checkpoint-then-crash (see the COLD-OPEN NOTE on test 1): reopen via the
        // full engine scan so resident state + IdMap rebuild from durable pages.
        defer graph_store.deinitGlobalStoreForTestCrash();
        const adapter = graph_store.getGlobalAdapter().?;

        // Each distinct committed entry applied EXACTLY ONCE — no churn re-apply,
        // so no orphan slot is minted on the unfixed build (this is the part that
        // is GREEN today and must remain GREEN after the fix).
        _ = try cluster_replication.applyMultiCreatePayload(a, store, payload, idx_a);
        _ = try cluster_replication.applyMultiCreatePayload(a, store, payload, idx_b);

        try adapter.checkpointAll();
        const durable = try adapter.edgeCount("default");
        std.debug.print("[test3 boot1] durable_edges={d} (expect 2 distinct)\n", .{durable});
        try std.testing.expectEqual(@as(u64, 2), durable);
    }

    {
        const store = try graph_store.initGlobalStore(a, data_dir);
        defer graph_store.deinitGlobalStore();

        try store.loadFromFile();
        // EARLY-READY (H3): force the deferred loop1/loop2 build (see test 1).
        store.ensureGraphHydrated("default");
        std.debug.print("[test3 boot2] mem_edges={d}\n", .{store.edges.count()});

        // Both distinct edges survive as two logical edges.
        try std.testing.expectEqual(@as(usize, 2), store.edges.count());

        // Both distinct edges remain resolvable forward (the over-dedup guard).
        const id_map = store.getIdMap("default") orelse return error.IdMapNotLoaded;
        _ = id_map.edgeSlot(@as(u128, edge_id_a)) orelse return error.EdgeSlotMappingMissing;
        _ = id_map.edgeSlot(@as(u128, edge_id_b)) orelse return error.EdgeSlotMappingMissing;

        // No orphan slots, two clean physical slots.
        const slots = try scanEdgeSlots(store, "default", a);
        std.debug.print("[test3 boot2] physical_edges_scanned={d} unmapped_slots={d}\n", .{ slots.physical, slots.unmapped });
        try std.testing.expectEqual(@as(usize, 0), slots.unmapped);
        try std.testing.expectEqual(@as(usize, 2), slots.physical);
    }
}
