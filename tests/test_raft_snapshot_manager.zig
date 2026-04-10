const std = @import("std");
const geode = @import("geode");
const graph_store = geode.graph_store;
const GraphStore = graph_store.GraphStore;
const PropertyValue = graph_store.PropertyValue;
const snapshot_manager = geode.distributed.raft_snapshot_manager;
const Crc32 = std.hash.crc.Crc32;

// CANARY: REQ=REQ-GQL-RAFT-SNAPSHOT; FEATURE="Raft Snapshot Persistence"; ASPECT=IntegrationTest; STATUS=TESTED; TEST=test_raft_snapshot_manager; OWNER=distributed; UPDATED=2026-04-09

test "snapshot_creation: non-empty store produces data with valid CRC" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    const nid = try store.createNode(&[_][]const u8{"Person"});
    try store.setNodeProperty(nid, "name", PropertyValue{ .String = "Alice" });
    try store.setNodeProperty(nid, "age", PropertyValue{ .Int = 30 });

    const result = try snapshot_manager.createSnapshotData(allocator, &store);
    defer allocator.free(result.data);

    // Data must be non-empty
    try std.testing.expect(result.data.len > 0);

    // CRC must match the data
    try std.testing.expectEqual(Crc32.hash(result.data), result.checksum);

    // Data should contain the node as JSON
    try std.testing.expect(std.mem.indexOf(u8, result.data, "\"type\":\"node\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.data, "\"Person\"") != null);
}

test "snapshot_roundtrip: nodes and edges survive serialize/deserialize" {
    const allocator = std.testing.allocator;

    // Build a source store
    var src = try GraphStore.init(allocator);
    defer src.deinit();

    const n1 = try src.createNode(&[_][]const u8{"Person"});
    try src.setNodeProperty(n1, "name", PropertyValue{ .String = "Alice" });
    try src.setNodeProperty(n1, "age", PropertyValue{ .Int = 30 });

    const n2 = try src.createNode(&[_][]const u8{ "Person", "Employee" });
    try src.setNodeProperty(n2, "name", PropertyValue{ .String = "Bob" });
    try src.setNodeProperty(n2, "active", PropertyValue{ .Bool = true });

    const eid = try src.createEdge(n1, n2, "KNOWS");
    try src.setEdgeProperty(eid, "since", PropertyValue{ .Int = 2020 });

    // Create snapshot
    const snap = try snapshot_manager.createSnapshotData(allocator, &src);
    defer allocator.free(snap.data);

    // Install into a fresh destination store
    var dst = try GraphStore.init(allocator);
    defer dst.deinit();

    try snapshot_manager.installSnapshotData(allocator, &dst, snap.data, snap.checksum);

    // Verify node 1
    const r_n1 = dst.nodes.get(n1);
    try std.testing.expect(r_n1 != null);
    try std.testing.expectEqual(@as(usize, 1), r_n1.?.labels.len);
    try std.testing.expectEqualStrings("Person", r_n1.?.labels[0]);

    const name1 = r_n1.?.properties.get("name") orelse return error.TestUnexpectedResult;
    switch (name1) {
        .String => |s| try std.testing.expectEqualStrings("Alice", s),
        else => return error.TestUnexpectedResult,
    }
    const age1 = r_n1.?.properties.get("age") orelse return error.TestUnexpectedResult;
    switch (age1) {
        .Int => |v| try std.testing.expectEqual(@as(i64, 30), v),
        else => return error.TestUnexpectedResult,
    }

    // Verify node 2 with multiple labels
    const r_n2 = dst.nodes.get(n2);
    try std.testing.expect(r_n2 != null);
    try std.testing.expectEqual(@as(usize, 2), r_n2.?.labels.len);

    // Verify edge
    const r_edge = dst.edges.get(eid);
    try std.testing.expect(r_edge != null);
    try std.testing.expectEqual(n1, r_edge.?.from_id);
    try std.testing.expectEqual(n2, r_edge.?.to_id);
    try std.testing.expectEqualStrings("KNOWS", r_edge.?.label);

    const since = r_edge.?.properties.get("since") orelse return error.TestUnexpectedResult;
    switch (since) {
        .Int => |v| try std.testing.expectEqual(@as(i64, 2020), v),
        else => return error.TestUnexpectedResult,
    }
}

test "snapshot_checksum: installSnapshotData rejects wrong checksum" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    // Create a valid snapshot first
    const nid = try store.createNode(&[_][]const u8{"Test"});
    _ = nid;

    const snap = try snapshot_manager.createSnapshotData(allocator, &store);
    defer allocator.free(snap.data);

    // Corrupt the checksum
    var store2 = try GraphStore.init(allocator);
    defer store2.deinit();

    const bad_checksum = snap.checksum +% 1;
    const result = snapshot_manager.installSnapshotData(allocator, &store2, snap.data, bad_checksum);
    try std.testing.expectError(error.ChecksumMismatch, result);
}

test "snapshot_empty: empty store round-trips cleanly" {
    const allocator = std.testing.allocator;

    var src = try GraphStore.init(allocator);
    defer src.deinit();

    const snap = try snapshot_manager.createSnapshotData(allocator, &src);
    defer allocator.free(snap.data);

    var dst = try GraphStore.init(allocator);
    defer dst.deinit();

    // Should succeed even with empty data
    try snapshot_manager.installSnapshotData(allocator, &dst, snap.data, snap.checksum);

    // Destination should be empty
    try std.testing.expectEqual(@as(u32, 0), dst.nodes.count());
    try std.testing.expectEqual(@as(u32, 0), dst.edges.count());
}

test "snapshot_replaces: install clears existing data before applying" {
    const allocator = std.testing.allocator;

    // Create store with initial data
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    _ = try store.createNode(&[_][]const u8{"OldNode"});
    try std.testing.expectEqual(@as(u32, 1), store.nodes.count());

    // Snapshot an empty store
    var empty = try GraphStore.init(allocator);
    defer empty.deinit();

    const snap = try snapshot_manager.createSnapshotData(allocator, &empty);
    defer allocator.free(snap.data);

    // Install empty snapshot into the store with data
    try snapshot_manager.installSnapshotData(allocator, &store, snap.data, snap.checksum);

    // The old node should be gone
    try std.testing.expectEqual(@as(u32, 0), store.nodes.count());
}
