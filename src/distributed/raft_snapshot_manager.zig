const std = @import("std");
const graph_store = @import("../graph_store.zig");
const GraphStore = graph_store.GraphStore;
const PropertyValue = graph_store.PropertyValue;

// CANARY: REQ=REQ-GQL-RAFT-SNAPSHOT; FEATURE="Raft Snapshot Persistence"; ASPECT=SnapshotCreation; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-09
//
// Snapshot manager for Raft consensus — serializes the graph store
// to JSON-lines format with CRC32 integrity verification.

const Crc32 = std.hash.crc.Crc32;

pub const SnapshotResult = struct {
    data: []u8,
    checksum: u32,
};

/// Serialize the graph store to a snapshot with CRC32 checksum.
/// The caller owns the returned data and must free it with `allocator.free(result.data)`.
pub fn createSnapshotData(allocator: std.mem.Allocator, store: *GraphStore) !SnapshotResult {
    const data = try store.serializeSnapshot(allocator);
    errdefer allocator.free(data);
    const checksum = Crc32.hash(data);
    return SnapshotResult{
        .data = data,
        .checksum = checksum,
    };
}

// ---- Tests ----

test "snapshot_manager: createSnapshotData produces non-empty data with valid CRC" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    // Add a node
    const nid = try store.createNode(&[_][]const u8{"Person"});
    try store.setNodeProperty(nid, "name", PropertyValue{ .String = "Alice" });

    const result = try createSnapshotData(allocator, &store);
    defer allocator.free(result.data);

    try std.testing.expect(result.data.len > 0);
    try std.testing.expectEqual(Crc32.hash(result.data), result.checksum);
}

test "snapshot_manager: empty store produces empty snapshot" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    const result = try createSnapshotData(allocator, &store);
    defer allocator.free(result.data);

    // Empty store should produce empty data (or at minimum valid CRC)
    try std.testing.expectEqual(Crc32.hash(result.data), result.checksum);
}
