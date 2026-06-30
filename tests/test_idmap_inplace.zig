// SPDX-License-Identifier: Apache-2.0
// Copyright 2024-2025 CodePros
//
// PHASE 4 (mmap-in-place IdMap): the PARITY ORACLE and its supporting
// regression tests. A `.mmap_backed` IdMap (snapshot mmap'd as an immutable
// BASE + an in-memory OVERLAY + tombstones) MUST return byte-for-byte identical
// results to an equivalent `.resident` IdMap for EVERY operation after ANY
// insert/insertWithSlot/remove/re-add sequence. The MERGE-MISS dedup authority
// (a base-only entry missed by insert => a duplicate node => corruption) is the
// crux exercised here.

const std = @import("std");
const idm = @import("id_map");
const IdMap = idm.IdMap;

// Deterministic, non-zero, unique UUID generators (real UUIDv7 is never 0, so
// 0 is safe as the reverse-region hole sentinel; we never generate 0 here).
fn nodeUuid(i: u64) u128 {
    return (@as(u128, i + 1) << 64) | 0x7000_0000_0000_0001;
}
fn edgeUuid(i: u64) u128 {
    return (@as(u128, i + 1) << 64) | 0x7000_0000_0000_00FF;
}

/// Build a `.mmap_backed` IdMap whose BASE is the saved snapshot of `seed`.
/// The returned map has an EMPTY overlay (the open-path O(1) shape).
fn mmapBackedFrom(a: std.mem.Allocator, dir: std.Io.Dir, seed: *IdMap) !IdMap {
    try seed.saveSnapshot(dir, 0xABCD);
    const snap = (try IdMap.loadSnapshot(dir)).?;
    var mm = IdMap.init(a);
    mm.adoptSnapshotAsBase(snap);
    return mm;
}

fn sortedNodeUuids(a: std.mem.Allocator, map: *IdMap) ![]u128 {
    var list: std.ArrayList(u128) = .empty;
    errdefer list.deinit(a);
    var it = map.nodeUuidIterator();
    while (it.next()) |u| try list.append(a, u);
    const out = try list.toOwnedSlice(a);
    std.mem.sort(u128, out, {}, std.sort.asc(u128));
    return out;
}

fn sortedEdgeUuids(a: std.mem.Allocator, map: *IdMap) ![]u128 {
    var list: std.ArrayList(u128) = .empty;
    errdefer list.deinit(a);
    var it = map.edgeUuidIterator();
    while (it.next()) |u| try list.append(a, u);
    const out = try list.toOwnedSlice(a);
    std.mem.sort(u128, out, {}, std.sort.asc(u128));
    return out;
}

/// Assert FULL parity between a resident reference and an mmap_backed map.
fn assertParity(
    a: std.mem.Allocator,
    ref: *IdMap,
    mm: *IdMap,
    known_nodes: []const u128,
    known_edges: []const u128,
) !void {
    const eq = std.testing.expectEqual;

    try eq(ref.nodeCount(), mm.nodeCount());
    try eq(ref.edgeCount(), mm.edgeCount());
    try eq(ref.next_node_slot, mm.next_node_slot);
    try eq(ref.next_edge_slot, mm.next_edge_slot);
    try eq(ref.maxNodeUuid(), mm.maxNodeUuid());
    try eq(ref.maxEdgeUuid(), mm.maxEdgeUuid());

    // Forward parity over every uuid ever used (live + deleted -> both null).
    for (known_nodes) |u| try eq(ref.nodeSlot(u), mm.nodeSlot(u));
    for (known_edges) |u| try eq(ref.edgeSlot(u), mm.edgeSlot(u));

    // Reverse parity over the full slot range plus one past the end.
    var slot: u64 = 0;
    const n_hi = @max(ref.next_node_slot, mm.next_node_slot) + 1;
    while (slot <= n_hi) : (slot += 1) try eq(ref.nodeUuid(slot), mm.nodeUuid(slot));
    slot = 0;
    const e_hi = @max(ref.next_edge_slot, mm.next_edge_slot) + 1;
    while (slot <= e_hi) : (slot += 1) try eq(ref.edgeUuid(slot), mm.edgeUuid(slot));

    // Iterator parity (sorted live set).
    const ref_nodes = try sortedNodeUuids(a, ref);
    defer a.free(ref_nodes);
    const mm_nodes = try sortedNodeUuids(a, mm);
    defer a.free(mm_nodes);
    try std.testing.expectEqualSlices(u128, ref_nodes, mm_nodes);

    const ref_edges = try sortedEdgeUuids(a, ref);
    defer a.free(ref_edges);
    const mm_edges = try sortedEdgeUuids(a, mm);
    defer a.free(mm_edges);
    try std.testing.expectEqualSlices(u128, ref_edges, mm_edges);
}

test "PARITY ORACLE: mmap_backed == resident over a randomized op script" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // ---- Build identical INITIAL data into the resident reference. ----
    var ref = IdMap.init(a);
    defer ref.deinit();

    const INIT_N: u64 = 50;
    const INIT_E: u64 = 30;
    var i: u64 = 0;
    while (i < INIT_N) : (i += 1) _ = try ref.insertNode(nodeUuid(i));
    i = 0;
    while (i < INIT_E) : (i += 1) _ = try ref.insertEdge(edgeUuid(i));
    // A few initial deletes -> reverse holes in the base.
    _ = ref.removeNode(nodeUuid(5));
    _ = ref.removeNode(nodeUuid(40));
    _ = ref.removeEdge(edgeUuid(7));

    // ---- BASE = snapshot of the reference; mm starts with empty overlay. ----
    var mm = try mmapBackedFrom(a, tmp.dir, &ref);
    defer mm.deinit();
    try std.testing.expectEqual(IdMap.Mode.mmap_backed, mm.mode);

    // Track every uuid ever used so forward parity probes deleted ones too.
    var known_nodes: std.ArrayList(u128) = .empty;
    defer known_nodes.deinit(a);
    var known_edges: std.ArrayList(u128) = .empty;
    defer known_edges.deinit(a);
    i = 0;
    while (i < INIT_N) : (i += 1) try known_nodes.append(a, nodeUuid(i));
    i = 0;
    while (i < INIT_E) : (i += 1) try known_edges.append(a, edgeUuid(i));

    try assertParity(a, &ref, &mm, known_nodes.items, known_edges.items);

    // ---- Randomized op script applied to BOTH; parity after EVERY op. ----
    var prng = std.Random.DefaultPrng.init(0x5EA1_F00D_1234_5678);
    const rnd = prng.random();
    var next_new: u64 = 1000; // fresh-uuid counter, disjoint from init range

    var op: u64 = 0;
    while (op < 400) : (op += 1) {
        const choice = rnd.intRangeLessThan(u8, 0, 10);
        switch (choice) {
            0, 1 => { // insert a brand-new node
                const u = nodeUuid(next_new);
                next_new += 1;
                const s_ref = try ref.insertNode(u);
                const s_mm = try mm.insertNode(u);
                try std.testing.expectEqual(s_ref, s_mm);
                try known_nodes.append(a, u);
            },
            2 => { // insertNodeWithSlot: new uuid at a chosen (maybe-gapped) slot
                const u = nodeUuid(next_new);
                next_new += 1;
                const s = ref.next_node_slot + rnd.intRangeLessThan(u64, 0, 4);
                try ref.insertNodeWithSlot(u, s);
                try mm.insertNodeWithSlot(u, s);
                try known_nodes.append(a, u);
            },
            3 => { // insertNodeWithSlot: re-map an EXISTING uuid to a fresh slot
                if (known_nodes.items.len > 0) {
                    const u = known_nodes.items[rnd.intRangeLessThan(usize, 0, known_nodes.items.len)];
                    const s = ref.next_node_slot + rnd.intRangeLessThan(u64, 0, 3);
                    try ref.insertNodeWithSlot(u, s);
                    try mm.insertNodeWithSlot(u, s);
                }
            },
            4 => { // remove an existing (or already-removed) node
                if (known_nodes.items.len > 0) {
                    const u = known_nodes.items[rnd.intRangeLessThan(usize, 0, known_nodes.items.len)];
                    try std.testing.expectEqual(ref.removeNode(u), mm.removeNode(u));
                }
            },
            5 => { // re-add a known node (re-add-after-tombstone path)
                if (known_nodes.items.len > 0) {
                    const u = known_nodes.items[rnd.intRangeLessThan(usize, 0, known_nodes.items.len)];
                    try std.testing.expectEqual(try ref.insertNode(u), try mm.insertNode(u));
                }
            },
            6, 7 => { // insert a brand-new edge
                const u = edgeUuid(next_new);
                next_new += 1;
                try std.testing.expectEqual(try ref.insertEdge(u), try mm.insertEdge(u));
                try known_edges.append(a, u);
            },
            8 => { // remove an existing edge
                if (known_edges.items.len > 0) {
                    const u = known_edges.items[rnd.intRangeLessThan(usize, 0, known_edges.items.len)];
                    try std.testing.expectEqual(ref.removeEdge(u), mm.removeEdge(u));
                }
            },
            else => { // edge insertWithSlot + re-add
                const u = edgeUuid(next_new);
                next_new += 1;
                const s = ref.next_edge_slot + rnd.intRangeLessThan(u64, 0, 3);
                try ref.insertEdgeWithSlot(u, s);
                try mm.insertEdgeWithSlot(u, s);
                try known_edges.append(a, u);
            },
        }
        try assertParity(a, &ref, &mm, known_nodes.items, known_edges.items);
    }
}

test "MERGE-MISS regression: base-only uuid is deduped, no slot/count drift" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var seed = IdMap.init(a);
    defer seed.deinit();
    var i: u64 = 0;
    while (i < 8) : (i += 1) _ = try seed.insertNode(nodeUuid(i));

    var mm = try mmapBackedFrom(a, tmp.dir, &seed);
    defer mm.deinit();

    const base_slot = seed.nodeSlot(nodeUuid(3)).?;
    const next_before = mm.next_node_slot;
    const count_before = mm.nodeCount();

    // insertNode of a uuid that lives ONLY in base MUST return the existing
    // slot and allocate NOTHING (else the node is duplicated = corruption).
    const got = try mm.insertNode(nodeUuid(3));
    try std.testing.expectEqual(base_slot, got);
    try std.testing.expectEqual(next_before, mm.next_node_slot);
    try std.testing.expectEqual(count_before, mm.nodeCount());

    // tombstone-then-reinsert => a FRESH slot; the OLD slot reads null.
    try std.testing.expect(mm.removeNode(nodeUuid(3)));
    try std.testing.expectEqual(@as(?u64, null), mm.nodeSlot(nodeUuid(3)));
    const fresh = try mm.insertNode(nodeUuid(3));
    try std.testing.expect(fresh != base_slot);
    try std.testing.expectEqual(@as(u64, next_before), fresh);
    try std.testing.expectEqual(@as(?u128, null), mm.nodeUuid(base_slot));
    try std.testing.expectEqual(@as(?u64, fresh), mm.nodeSlot(nodeUuid(3)));
    try std.testing.expectEqual(count_before, mm.nodeCount());
}

test "checkpoint round-trip: mmap_backed + overlay + tombstones -> save -> reload -> parity" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Resident reference.
    var ref = IdMap.init(a);
    defer ref.deinit();
    var i: u64 = 0;
    while (i < 20) : (i += 1) _ = try ref.insertNode(nodeUuid(i));
    i = 0;
    while (i < 12) : (i += 1) _ = try ref.insertEdge(edgeUuid(i));

    var mm = try mmapBackedFrom(a, tmp.dir, &ref);
    defer mm.deinit();

    // Mutate BOTH identically: overlay inserts, tombstones, a re-add.
    _ = try ref.insertNode(nodeUuid(100));
    _ = try mm.insertNode(nodeUuid(100));
    _ = ref.removeNode(nodeUuid(2));
    _ = mm.removeNode(nodeUuid(2));
    _ = ref.removeNode(nodeUuid(9));
    _ = mm.removeNode(nodeUuid(9));
    _ = try ref.insertNode(nodeUuid(9)); // re-add at fresh slot
    _ = try mm.insertNode(nodeUuid(9));
    _ = try ref.insertEdge(edgeUuid(200));
    _ = try mm.insertEdge(edgeUuid(200));
    _ = ref.removeEdge(edgeUuid(3));
    _ = mm.removeEdge(edgeUuid(3));

    // Serialize the MERGED mmap_backed state and reload into a fresh base.
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    try mm.saveSnapshot(tmp2.dir, 0x99);
    var reopened = blk: {
        const snap = (try IdMap.loadSnapshot(tmp2.dir)).?;
        var r = IdMap.init(a);
        r.adoptSnapshotAsBase(snap);
        break :blk r;
    };
    defer reopened.deinit();
    try std.testing.expectEqual(IdMap.Mode.mmap_backed, reopened.mode);

    var known_nodes: std.ArrayList(u128) = .empty;
    defer known_nodes.deinit(a);
    var known_edges: std.ArrayList(u128) = .empty;
    defer known_edges.deinit(a);
    i = 0;
    while (i < 20) : (i += 1) try known_nodes.append(a, nodeUuid(i));
    try known_nodes.append(a, nodeUuid(100));
    i = 0;
    while (i < 12) : (i += 1) try known_edges.append(a, edgeUuid(i));
    try known_edges.append(a, edgeUuid(200));

    try assertParity(a, &ref, &reopened, known_nodes.items, known_edges.items);
}

test "clone materializes a resident copy with merged parity" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var ref = IdMap.init(a);
    defer ref.deinit();
    var i: u64 = 0;
    while (i < 16) : (i += 1) _ = try ref.insertNode(nodeUuid(i));
    i = 0;
    while (i < 10) : (i += 1) _ = try ref.insertEdge(edgeUuid(i));

    var mm = try mmapBackedFrom(a, tmp.dir, &ref);
    defer mm.deinit();

    // Overlay churn on both.
    _ = try ref.insertNode(nodeUuid(50));
    _ = try mm.insertNode(nodeUuid(50));
    _ = ref.removeNode(nodeUuid(4));
    _ = mm.removeNode(nodeUuid(4));
    _ = try ref.insertEdge(edgeUuid(60));
    _ = try mm.insertEdge(edgeUuid(60));

    var clone = try mm.clone(a);
    defer clone.deinit();
    try std.testing.expectEqual(IdMap.Mode.resident, clone.mode);

    var known_nodes: std.ArrayList(u128) = .empty;
    defer known_nodes.deinit(a);
    var known_edges: std.ArrayList(u128) = .empty;
    defer known_edges.deinit(a);
    i = 0;
    while (i < 16) : (i += 1) try known_nodes.append(a, nodeUuid(i));
    try known_nodes.append(a, nodeUuid(50));
    i = 0;
    while (i < 10) : (i += 1) try known_edges.append(a, edgeUuid(i));
    try known_edges.append(a, edgeUuid(60));

    // Clone (resident) must match the resident reference exactly.
    try assertParity(a, &ref, &clone, known_nodes.items, known_edges.items);
}

test "concurrency: readers over base run alongside overlay writers under mutex" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var seed = IdMap.init(a);
    defer seed.deinit();
    var i: u64 = 0;
    while (i < 200) : (i += 1) _ = try seed.insertNode(nodeUuid(i));

    var mm = try mmapBackedFrom(a, tmp.dir, &seed);
    defer mm.deinit();

    const Ctx = struct {
        map: *IdMap,
        fn reader(m: *IdMap) void {
            var k: u64 = 0;
            while (k < 20000) : (k += 1) {
                const idx = k % 200;
                // base reads must never tear / crash while writers mutate overlay
                _ = m.nodeSlot(nodeUuid(idx));
                _ = m.nodeUuid(idx);
                _ = m.nodeCount();
            }
        }
        fn writer(m: *IdMap) void {
            var k: u64 = 0;
            while (k < 4000) : (k += 1) {
                _ = m.insertNode(nodeUuid(10_000 + k)) catch return;
                if (k % 3 == 0) _ = m.removeNode(nodeUuid(k % 200));
                if (k % 5 == 0) _ = m.insertNode(nodeUuid(k % 200)) catch return; // re-add
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    threads[0] = try std.Thread.spawn(.{}, Ctx.reader, .{&mm});
    threads[1] = try std.Thread.spawn(.{}, Ctx.reader, .{&mm});
    threads[2] = try std.Thread.spawn(.{}, Ctx.writer, .{&mm});
    threads[3] = try std.Thread.spawn(.{}, Ctx.reader, .{&mm});
    for (threads) |t| t.join();

    // Survived without a torn read / crash; the map is still internally
    // consistent (every live forward uuid reverse-maps back to its slot).
    var it = mm.nodeUuidIterator();
    while (it.next()) |u| {
        const s = mm.nodeSlot(u).?;
        try std.testing.expectEqual(@as(?u128, u), mm.nodeUuid(s));
    }
}
