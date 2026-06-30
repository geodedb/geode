// SPDX-License-Identifier: Apache-2.0
// Copyright 2024-2025 CodePros
//
// Phase 1a (sub-second startup): tests for the mmap-able IdMap snapshot.
// Proves the on-disk format round-trips exactly (including delete-holes),
// that a corrupt/truncated/absent file gates to null, and that the format +
// binary search hold at ~100k scale.

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

test "IdMap snapshot: round-trip incl delete-holes (node + edge)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var map = IdMap.init(a);
    defer map.deinit();

    const N: u64 = 64;
    const M: u64 = 48;
    var i: u64 = 0;
    while (i < N) : (i += 1) _ = try map.insertNode(nodeUuid(i));
    i = 0;
    while (i < M) : (i += 1) _ = try map.insertEdge(edgeUuid(i));

    // Delete a few in each namespace -> reverse-region holes; slots are never
    // recycled, so next_*_slot stays at N / M.
    try std.testing.expect(map.removeNode(nodeUuid(3)));
    try std.testing.expect(map.removeNode(nodeUuid(17)));
    try std.testing.expect(map.removeNode(nodeUuid(N - 1)));
    try std.testing.expect(map.removeEdge(edgeUuid(0)));
    try std.testing.expect(map.removeEdge(edgeUuid(25)));

    const counter: u64 = 0xDEAD_BEEF_1234;
    try map.saveSnapshot(tmp.dir, counter);

    var snap = (try IdMap.loadSnapshot(tmp.dir)).?;
    defer snap.deinit();

    // Header / counts preserved.
    try std.testing.expectEqual(counter, snap.manifest_counter);
    try std.testing.expectEqual(map.next_node_slot, snap.next_node_slot);
    try std.testing.expectEqual(map.next_edge_slot, snap.next_edge_slot);
    try std.testing.expectEqual(@as(u64, map.nodeCount()), snap.node_fwd_count);
    try std.testing.expectEqual(@as(u64, map.edgeCount()), snap.edge_fwd_count);

    // Reverse parity for EVERY slot in range, plus one past the end.
    var slot: u64 = 0;
    while (slot < map.next_node_slot) : (slot += 1) {
        try std.testing.expectEqual(map.nodeUuid(slot), snap.nodeUuidAt(slot));
    }
    try std.testing.expectEqual(@as(?u128, null), snap.nodeUuidAt(map.next_node_slot));

    slot = 0;
    while (slot < map.next_edge_slot) : (slot += 1) {
        try std.testing.expectEqual(map.edgeUuid(slot), snap.edgeUuidAt(slot));
    }
    try std.testing.expectEqual(@as(?u128, null), snap.edgeUuidAt(map.next_edge_slot));

    // Forward parity for every original uuid (deleted ones must be null in both).
    i = 0;
    while (i < N) : (i += 1) {
        try std.testing.expectEqual(map.nodeSlot(nodeUuid(i)), snap.nodeSlotOf(nodeUuid(i)));
    }
    i = 0;
    while (i < M) : (i += 1) {
        try std.testing.expectEqual(map.edgeSlot(edgeUuid(i)), snap.edgeSlotOf(edgeUuid(i)));
    }

    // Explicit hole assertions.
    try std.testing.expectEqual(@as(?u128, null), snap.nodeUuidAt(3));
    try std.testing.expectEqual(@as(?u64, null), snap.nodeSlotOf(nodeUuid(3)));
    try std.testing.expectEqual(@as(?u128, null), snap.edgeUuidAt(0));
    try std.testing.expectEqual(@as(?u64, null), snap.edgeSlotOf(edgeUuid(0)));

    // Never-inserted uuids miss.
    try std.testing.expectEqual(@as(?u64, null), snap.nodeSlotOf(0xABCDEF));
    try std.testing.expectEqual(@as(?u64, null), snap.edgeSlotOf(0x123456));
}

test "IdMap snapshot: missing file -> null" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const res = try IdMap.loadSnapshot(tmp.dir);
    try std.testing.expect(res == null);
}

test "IdMap snapshot: CRC corruption -> null" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var map = IdMap.init(a);
    defer map.deinit();
    var i: u64 = 0;
    while (i < 10) : (i += 1) _ = try map.insertNode(nodeUuid(i));
    while (i < 16) : (i += 1) _ = try map.insertEdge(edgeUuid(i));
    try map.saveSnapshot(tmp.dir, 7);

    // Flip a byte inside the payload (header region) -> CRC must fail.
    const io = std.Io.Threaded.global_single_threaded.io();
    {
        const f = try tmp.dir.openFile(io, "idmap.snapshot", .{ .mode = .read_write });
        defer f.close(io);
        var b: [1]u8 = undefined;
        _ = try f.readPositionalAll(io, &b, 30);
        b[0] ^= 0xFF;
        try f.writePositionalAll(io, &b, 30);
        try f.sync(io);
    }

    const res = try IdMap.loadSnapshot(tmp.dir);
    try std.testing.expect(res == null);
}

test "IdMap snapshot: truncation -> null" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var map = IdMap.init(a);
    defer map.deinit();
    var i: u64 = 0;
    while (i < 20) : (i += 1) _ = try map.insertNode(nodeUuid(i));
    try map.saveSnapshot(tmp.dir, 1);

    // Read the file, then rewrite it shorter (truncate by 10 bytes).
    const io = std.Io.Threaded.global_single_threaded.io();
    var buf: []u8 = undefined;
    {
        const f = try tmp.dir.openFile(io, "idmap.snapshot", .{});
        defer f.close(io);
        const len: usize = @intCast(try f.length(io));
        buf = try a.alloc(u8, len);
        _ = try f.readPositionalAll(io, buf, 0);
    }
    defer a.free(buf);
    {
        const f = try tmp.dir.createFile(io, "idmap.snapshot", .{}); // truncates
        defer f.close(io);
        try f.writePositionalAll(io, buf[0 .. buf.len - 10], 0);
        try f.sync(io);
    }

    const res = try IdMap.loadSnapshot(tmp.dir);
    try std.testing.expect(res == null);
}

test "IdMap snapshot: ~100k node + 100k edge round-trip" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var map = IdMap.init(a);
    defer map.deinit();

    const N: u64 = 100_000;
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        _ = try map.insertNode(nodeUuid(i));
        _ = try map.insertEdge(edgeUuid(i));
    }

    try map.saveSnapshot(tmp.dir, 99);
    var snap = (try IdMap.loadSnapshot(tmp.dir)).?;
    defer snap.deinit();

    try std.testing.expectEqual(N, snap.next_node_slot);
    try std.testing.expectEqual(N, snap.next_edge_slot);
    try std.testing.expectEqual(N, snap.node_fwd_count);
    try std.testing.expectEqual(N, snap.edge_fwd_count);

    // Verify forward (binary search) + reverse (direct index) for ALL entries.
    i = 0;
    while (i < N) : (i += 1) {
        try std.testing.expectEqual(@as(?u64, i), snap.nodeSlotOf(nodeUuid(i)));
        try std.testing.expectEqual(@as(?u128, nodeUuid(i)), snap.nodeUuidAt(i));
        try std.testing.expectEqual(@as(?u64, i), snap.edgeSlotOf(edgeUuid(i)));
        try std.testing.expectEqual(@as(?u128, edgeUuid(i)), snap.edgeUuidAt(i));
    }
    // A uuid not present anywhere misses.
    try std.testing.expectEqual(@as(?u64, null), snap.nodeSlotOf(nodeUuid(N + 5)));
}
