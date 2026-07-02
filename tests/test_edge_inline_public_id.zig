// CANARY: REQ=REQ-STORAGE-EDGE-INLINE-ID; FEATURE="InlineEdgePublicId"; ASPECT=NoPerEdgePropsPage; STATUS=TESTED; TEST=test_edge_inline_public_id; OWNER=storage; UPDATED=2026-07-02
//
// GAP-ENT-0024 (P5, geode adoption): the 64-bit PUBLIC edge id rides INLINE in
// the durable adjacency records (graph-storage v0.2.24 v2 blocks) instead of a
// per-edge `__geode_internal_edge_id` LEGACY property chain (one ≥8 KB props
// page per edge — ~113 GB at 13.8 M edges). Contract pinned here:
//
//   1. NEW edges (both create paths: minted `createEdgeWithGraphAndTenant` and
//      replicated `createEdgeWithIdInternal` via createEdgeWithId) write NO
//      `__geode_internal_edge_id` property, and the adjacency entry's
//      `public_id` equals the geode public edge id.
//   2. IdMap rebuild-from-scan (loop1, forced by deleting the IdMap snapshot)
//      resolves every v2 edge from the INLINE id — the per-edge property
//      fallback fetch does NOT run (graph_store.edge_id_property_fallback_reads
//      stays 0 for a fresh all-v2 store).
//   3. MIXED store: an edge written the OLD way (legacy engine slot with
//      public_id == 0 + `__geode_internal_edge_id` property — the pre-v0.2.24
//      on-disk shape) coexists with inline-id edges; after reopen BOTH resolve
//      (the legacy one through the permanent property-fallback read path).

const std = @import("std");
const geode = @import("geode");
const graph_store = geode.graph_store;
const GraphStore = graph_store.GraphStore;
const adapter_mod = geode.graph_storage_adapter;

const INTERNAL_EDGE_ID_KEY = graph_store.INTERNAL_EDGE_ID_PROPERTY_KEY;

fn dataDirFor(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

/// Delete every IdMap snapshot artifact under `data_dir` (recursive walk) so
/// the next open MUST rebuild the per-graph IdMap from the engine scan (loop1).
fn deleteIdMapSnapshots(a: std.mem.Allocator, data_dir: []const u8) !usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();

    var doomed: std.ArrayList([]u8) = .empty;
    defer {
        for (doomed.items) |p| a.free(p);
        doomed.deinit(a);
    }
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.basename, "idmap.snapshot") or
            std.mem.eql(u8, entry.basename, "idmap.snapshot.tmp") or
            std.mem.eql(u8, entry.basename, "id_map.dat") or
            std.mem.eql(u8, entry.basename, "id_map.dat.tmp"))
        {
            try doomed.append(a, try a.dupe(u8, entry.path));
        }
    }
    for (doomed.items) |p| try dir.deleteFile(io, p);
    return doomed.items.len;
}

/// Assert the `__geode_internal_edge_id` property is ABSENT for the edge slot
/// and that the outgoing adjacency entry carries `expected_public_id` inline.
fn expectInlineOnly(
    a: std.mem.Allocator,
    adapter: *adapter_mod.StorageAdapter,
    graph: []const u8,
    from_slot: u64,
    edge_slot: u64,
    expected_public_id: u64,
) !void {
    if (try adapter.getEdgeProperty(graph, from_slot, edge_slot, INTERNAL_EDGE_ID_KEY, a)) |prop| {
        adapter_mod.freeOwnedStorageProperty(a, prop);
        std.debug.print("FAIL: edge slot {d} still carries a __geode_internal_edge_id property page\n", .{edge_slot});
        return error.LegacyEdgeIdPropertyStillWritten;
    }
    var iter = try adapter.iterateOutgoingEdges(graph, from_slot, a);
    defer iter.deinit();
    var found = false;
    while (try iter.next()) |entry| {
        if (entry.edge_id != edge_slot) continue;
        found = true;
        if (entry.public_id != expected_public_id) {
            std.debug.print("FAIL: adjacency entry for slot {d}: inline public_id={d}, expected {d}\n", .{ edge_slot, entry.public_id, expected_public_id });
            return error.InlinePublicIdMismatch;
        }
    }
    try std.testing.expect(found);
}

// ===========================================================================
// Test 1 — NEW edges: no id property page, inline id on both create paths.
// ===========================================================================
test "GAP-ENT-0024: new-store edge create writes NO __geode_internal_edge_id property; inline public_id resolves on both create paths" {
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try dataDirFor(a, &tmp);
    defer a.free(data_dir);

    const labels = [_][]const u8{"InlineIdNode"};

    const store = try graph_store.initGlobalStore(a, data_dir);
    defer graph_store.deinitGlobalStore();
    const adapter = graph_store.getGlobalAdapter().?;

    try store.createNodeWithId(1001, &labels, "default");
    try store.createNodeWithId(1002, &labels, "default");

    // Path 1: minted id (createEdgeWithGraph -> createEdgeWithGraphAndTenant).
    const minted_id = try store.createEdgeWithGraph(1001, 1002, "KNOWS", "default");
    try std.testing.expect(minted_id != 0); // time-based ids are nonzero
    // Path 2: caller-supplied id (createEdgeWithId -> createEdgeWithIdInternal,
    // the replication-apply shape).
    try store.createEdgeWithId(9001, 1002, 1001, "LINKS", "default");

    const id_map = store.getIdMap("default") orelse return error.IdMapNotLoaded;
    const slot_1001 = id_map.nodeSlot(@as(u128, 1001)) orelse return error.NodeSlotMappingMissing;
    const slot_1002 = id_map.nodeSlot(@as(u128, 1002)) orelse return error.NodeSlotMappingMissing;
    const minted_slot = id_map.edgeSlot(@as(u128, minted_id)) orelse return error.EdgeSlotMappingMissing;
    const with_id_slot = id_map.edgeSlot(@as(u128, 9001)) orelse return error.EdgeSlotMappingMissing;

    try expectInlineOnly(a, adapter, "default", slot_1001, minted_slot, minted_id);
    try expectInlineOnly(a, adapter, "default", slot_1002, with_id_slot, 9001);

    // The public-id surface still resolves: forward + reverse IdMap round-trip
    // (the id space RETURN r / id(r) materialization reads from).
    try std.testing.expectEqual(@as(u128, minted_id), id_map.edgeUuid(minted_slot).?);
    try std.testing.expectEqual(@as(u128, 9001), id_map.edgeUuid(with_id_slot).?);
    // And the in-memory edge bodies carry the exact ids/endpoints.
    const minted_edge = store.edges.get(minted_id) orelse return error.EdgeNotFound;
    try std.testing.expectEqual(@as(u64, 1001), minted_edge.from_id);
    try std.testing.expectEqual(@as(u64, 1002), minted_edge.to_id);
    try std.testing.expectEqualStrings("KNOWS", minted_edge.label);
}

// ===========================================================================
// Test 2 — loop1 rebuild-from-scan uses the inline id, NOT the property fetch.
// ===========================================================================
test "GAP-ENT-0024: IdMap rebuild-from-scan (loop1) resolves v2 edges inline — zero per-edge property fallback reads" {
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try dataDirFor(a, &tmp);
    defer a.free(data_dir);

    const labels = [_][]const u8{"Loop1Node"};
    var minted_id: u64 = 0;

    // ---- Boot 1: fresh store, all-v2 edges, checkpoint. ----
    {
        const store = try graph_store.initGlobalStore(a, data_dir);
        defer graph_store.deinitGlobalStore();
        const adapter = graph_store.getGlobalAdapter().?;

        try store.createNodeWithId(2001, &labels, "default");
        try store.createNodeWithId(2002, &labels, "default");
        try store.createNodeWithId(2003, &labels, "default");
        minted_id = try store.createEdgeWithGraph(2001, 2002, "REL_A", "default");
        try store.createEdgeWithId(9101, 2002, 2003, "REL_B", "default");
        try adapter.checkpointAll();
    }

    // Force loop1: no IdMap snapshot may survive.
    const deleted = try deleteIdMapSnapshots(a, data_dir);
    std.debug.print("[loop1 test] deleted {d} IdMap snapshot artifact(s) to force rebuild-from-scan\n", .{deleted});

    // ---- Boot 2: rebuild from the engine scan; the fallback counter must not
    // move (every edge is v2 and carries its id inline). ----
    graph_store.edge_id_property_fallback_reads.store(0, .monotonic);
    {
        const store = try graph_store.initGlobalStore(a, data_dir);
        defer graph_store.deinitGlobalStore();

        try store.loadFromFile();
        // EARLY-READY defers the loop1/loop2 build; force it (the read-path
        // chokepoints do the same on first access).
        store.ensureGraphHydrated("default");

        const id_map = store.getIdMap("default") orelse return error.IdMapNotLoaded;
        // Ids exact: forward + reverse for both edges.
        const minted_slot = id_map.edgeSlot(@as(u128, minted_id)) orelse return error.EdgeSlotMappingMissing;
        try std.testing.expectEqual(@as(u128, minted_id), id_map.edgeUuid(minted_slot).?);
        const with_id_slot = id_map.edgeSlot(@as(u128, 9101)) orelse return error.EdgeSlotMappingMissing;
        try std.testing.expectEqual(@as(u128, 9101), id_map.edgeUuid(with_id_slot).?);
        try std.testing.expectEqual(@as(usize, 2), store.edges.count());

        const fallback_reads = graph_store.edge_id_property_fallback_reads.load(.monotonic);
        if (fallback_reads != 0) {
            std.debug.print("[loop1 test] FAIL: {d} per-edge __geode_internal_edge_id property fetch(es) ran for an all-v2 store\n", .{fallback_reads});
        }
        try std.testing.expectEqual(@as(u64, 0), fallback_reads);
    }
}

// ===========================================================================
// Test 3 — MIXED store: legacy property-tagged edge + inline edge both resolve.
// ===========================================================================
test "GAP-ENT-0024: mixed store — legacy property-tagged edge (pre-switch shape) and inline-id edge both resolve after reopen" {
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try dataDirFor(a, &tmp);
    defer a.free(data_dir);

    const labels = [_][]const u8{"MixedNode"};
    const legacy_public_id: u64 = 0xBEEF_CAFE_0000_0042;
    var inline_id: u64 = 0;

    // ---- Boot 1: one edge via the NEW inline path, one edge hand-built the
    // OLD way (legacy engine slot, public_id == 0, id persisted as the
    // `__geode_internal_edge_id` property) — byte-for-byte the pre-v0.2.24
    // on-disk shape. ----
    {
        const store = try graph_store.initGlobalStore(a, data_dir);
        defer graph_store.deinitGlobalStore();
        const adapter = graph_store.getGlobalAdapter().?;

        try store.createNodeWithId(3001, &labels, "default");
        try store.createNodeWithId(3002, &labels, "default");
        inline_id = try store.createEdgeWithGraph(3001, 3002, "NEW_REL", "default");

        const id_map = store.getIdMap("default") orelse return error.IdMapNotLoaded;
        const from_slot = id_map.nodeSlot(@as(u128, 3002)) orelse return error.NodeSlotMappingMissing;
        const to_slot = id_map.nodeSlot(@as(u128, 3001)) orelse return error.NodeSlotMappingMissing;

        // OLD-way fixture: legacy adapter surface writes public_id == 0 into
        // the adjacency entry; the public id goes into the property, exactly
        // like the deleted persistEdgePublicId used to do.
        const legacy_slot = try adapter.createEdge("default", from_slot, to_slot, "OLD_REL");
        var id_buf: [16]u8 = undefined;
        const encoded = try std.fmt.bufPrint(&id_buf, "{x:0>16}", .{legacy_public_id});
        try adapter.setEdgeProperty("default", from_slot, to_slot, legacy_slot, INTERNAL_EDGE_ID_KEY, .{ .String = encoded });

        try adapter.checkpointAll();
    }

    // Force the rebuild-from-scan so BOTH resolution routes actually run.
    _ = try deleteIdMapSnapshots(a, data_dir);

    graph_store.edge_id_property_fallback_reads.store(0, .monotonic);
    // ---- Boot 2: both edges must resolve — the inline one without the
    // property fetch, the legacy one THROUGH it. ----
    {
        const store = try graph_store.initGlobalStore(a, data_dir);
        defer graph_store.deinitGlobalStore();

        try store.loadFromFile();
        // EARLY-READY defers the loop1/loop2 build; force it so BOTH
        // resolution routes (inline + property fallback) actually run now.
        store.ensureGraphHydrated("default");

        const id_map = store.getIdMap("default") orelse return error.IdMapNotLoaded;
        const inline_slot = id_map.edgeSlot(@as(u128, inline_id)) orelse {
            std.debug.print("[mixed test] FAIL: inline-id edge {d} unresolvable after reopen\n", .{inline_id});
            return error.EdgeSlotMappingMissing;
        };
        try std.testing.expectEqual(@as(u128, inline_id), id_map.edgeUuid(inline_slot).?);

        const legacy_slot = id_map.edgeSlot(@as(u128, legacy_public_id)) orelse {
            std.debug.print("[mixed test] FAIL: legacy property-tagged edge {x} unresolvable after reopen (read-both broken)\n", .{legacy_public_id});
            return error.EdgeSlotMappingMissing;
        };
        try std.testing.expectEqual(@as(u128, legacy_public_id), id_map.edgeUuid(legacy_slot).?);

        // Both logical edges materialized.
        try std.testing.expectEqual(@as(usize, 2), store.edges.count());

        // The legacy edge is the ONLY one allowed to take the property
        // fallback; the inline edge must not. (Exactly one fallback read —
        // the legacy edge's loop1 resolution.)
        const fallback_reads = graph_store.edge_id_property_fallback_reads.load(.monotonic);
        try std.testing.expect(fallback_reads >= 1);
    }
}
