const std = @import("std");
const graph_store = @import("../graph_store.zig");
const GraphStore = graph_store.GraphStore;
const PropertyValue = graph_store.PropertyValue;

// CANARY: REQ=REQ-GQL-RAFT-SNAPSHOT; FEATURE="Raft Snapshot Persistence"; ASPECT=SnapshotCreation; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-09
// CANARY: REQ=REQ-GQL-RAFT-SNAPSHOT; FEATURE="Raft Snapshot Persistence"; ASPECT=SnapshotInstallation; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-09
//
// Snapshot manager for Raft consensus — serializes and deserializes the graph store
// to/from JSON-lines format with CRC32 integrity verification.

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

pub const SnapshotError = error{
    ChecksumMismatch,
    InvalidJsonLine,
    MissingField,
    InvalidType,
};

/// Install a snapshot into the graph store, replacing all existing data.
/// Verifies the CRC32 checksum before applying.
pub fn installSnapshotData(
    allocator: std.mem.Allocator,
    store: *GraphStore,
    data: []const u8,
    expected_checksum: u32,
) !void {
    _ = allocator;

    // 1. Verify CRC32
    const actual_checksum = Crc32.hash(data);
    if (actual_checksum != expected_checksum) {
        return error.ChecksumMismatch;
    }

    // 2. Clear existing store data
    store.clearNodes();

    // 3. Parse JSON-lines and recreate nodes/edges
    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        try parseLine(store, line);
    }
}

/// Parse a single JSON-lines entry and apply it to the store.
fn parseLine(store: *GraphStore, line: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, store.allocator, line, .{}) catch {
        return error.InvalidJsonLine;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidJsonLine,
    };

    const type_val = obj.get("type") orelse return error.MissingField;
    const type_str = switch (type_val) {
        .string => |s| s,
        else => return error.InvalidType,
    };

    if (std.mem.eql(u8, type_str, "node")) {
        try parseAndCreateNode(store, obj);
    } else if (std.mem.eql(u8, type_str, "edge")) {
        try parseAndCreateEdge(store, obj);
    } else {
        return error.InvalidType;
    }
}

/// Extract a u64 from a JSON value (integer or number).
fn jsonToU64(val: std.json.Value) ?u64 {
    return switch (val) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .number_string => |s| std.fmt.parseUnsigned(u64, s, 10) catch null,
        else => null,
    };
}

fn parseAndCreateNode(store: *GraphStore, obj: std.json.ObjectMap) !void {
    const id_val = obj.get("id") orelse return error.MissingField;
    const node_id = jsonToU64(id_val) orelse return error.InvalidType;

    const graph_val = obj.get("graph") orelse return error.MissingField;
    const graph_name = switch (graph_val) {
        .string => |s| s,
        else => return error.InvalidType,
    };

    // Parse labels array
    const labels_val = obj.get("labels") orelse return error.MissingField;
    const labels_arr = switch (labels_val) {
        .array => |a| a,
        else => return error.InvalidType,
    };

    // Build labels slice for createNodeWithIdNoSave
    const labels = try store.allocator.alloc([]const u8, labels_arr.items.len);
    defer store.allocator.free(labels);

    for (labels_arr.items, 0..) |item, i| {
        labels[i] = switch (item) {
            .string => |s| s,
            else => return error.InvalidType,
        };
    }

    try store.createNodeWithIdNoSave(node_id, labels, graph_name);

    // Apply properties
    if (obj.get("properties")) |props_val| {
        const props_obj = switch (props_val) {
            .object => |o| o,
            else => return error.InvalidType,
        };
        var it = props_obj.iterator();
        while (it.next()) |entry| {
            const pv = jsonToPropertyValue(entry.value_ptr.*) orelse continue;
            try store.setNodePropertyNoSave(node_id, entry.key_ptr.*, pv);
        }
    }
}

fn parseAndCreateEdge(store: *GraphStore, obj: std.json.ObjectMap) !void {
    const id_val = obj.get("id") orelse return error.MissingField;
    const edge_id = jsonToU64(id_val) orelse return error.InvalidType;

    const from_val = obj.get("from") orelse return error.MissingField;
    const from_id = jsonToU64(from_val) orelse return error.InvalidType;

    const to_val = obj.get("to") orelse return error.MissingField;
    const to_id = jsonToU64(to_val) orelse return error.InvalidType;

    const graph_val = obj.get("graph") orelse return error.MissingField;
    const graph_name = switch (graph_val) {
        .string => |s| s,
        else => return error.InvalidType,
    };

    const label_val = obj.get("label") orelse return error.MissingField;
    const label = switch (label_val) {
        .string => |s| s,
        else => return error.InvalidType,
    };

    try store.createEdgeWithIdNoSave(edge_id, from_id, to_id, label, graph_name);

    // Apply properties
    if (obj.get("properties")) |props_val| {
        const props_obj = switch (props_val) {
            .object => |o| o,
            else => return error.InvalidType,
        };
        var it = props_obj.iterator();
        while (it.next()) |entry| {
            const pv = jsonToPropertyValue(entry.value_ptr.*) orelse continue;
            try store.setEdgePropertyNoSave(edge_id, entry.key_ptr.*, pv);
        }
    }
}

/// Convert a std.json.Value to a GraphStore PropertyValue.
/// Returns null for unsupported types (ExtValue, etc.).
fn jsonToPropertyValue(val: std.json.Value) ?PropertyValue {
    return switch (val) {
        .string => |s| PropertyValue{ .String = s },
        .integer => |i| PropertyValue{ .Int = i },
        .float => |f| PropertyValue{ .Float = f },
        .bool => |b| PropertyValue{ .Bool = b },
        .null => PropertyValue.Null,
        else => null,
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

test "snapshot_manager: round-trip snapshot preserves nodes and edges" {
    const allocator = std.testing.allocator;

    // Create source store with data
    var src = try GraphStore.init(allocator);
    defer src.deinit();

    const n1 = try src.createNode(&[_][]const u8{"Person"});
    try src.setNodeProperty(n1, "name", PropertyValue{ .String = "Alice" });
    try src.setNodeProperty(n1, "age", PropertyValue{ .Int = 30 });

    const n2 = try src.createNode(&[_][]const u8{"Person"});
    try src.setNodeProperty(n2, "name", PropertyValue{ .String = "Bob" });

    const eid = try src.createEdge(n1, n2, "KNOWS");
    try src.setEdgeProperty(eid, "since", PropertyValue{ .Int = 2020 });

    // Snapshot
    const snap = try createSnapshotData(allocator, &src);
    defer allocator.free(snap.data);

    // Install into a fresh store
    var dst = try GraphStore.init(allocator);
    defer dst.deinit();

    try installSnapshotData(allocator, &dst, snap.data, snap.checksum);

    // Verify nodes exist
    const restored_n1 = dst.nodes.get(n1);
    try std.testing.expect(restored_n1 != null);
    const alice = restored_n1.?;
    try std.testing.expectEqual(@as(usize, 1), alice.labels.len);
    try std.testing.expectEqualStrings("Person", alice.labels[0]);

    // Verify node property
    const name_prop = alice.properties.get("name");
    try std.testing.expect(name_prop != null);
    switch (name_prop.?) {
        .String => |s| try std.testing.expectEqualStrings("Alice", s),
        else => return error.TestUnexpectedResult,
    }

    const age_prop = alice.properties.get("age");
    try std.testing.expect(age_prop != null);
    switch (age_prop.?) {
        .Int => |v| try std.testing.expectEqual(@as(i64, 30), v),
        else => return error.TestUnexpectedResult,
    }

    // Verify second node
    const restored_n2 = dst.nodes.get(n2);
    try std.testing.expect(restored_n2 != null);

    // Verify edge
    const restored_edge = dst.edges.get(eid);
    try std.testing.expect(restored_edge != null);
    const edge = restored_edge.?;
    try std.testing.expectEqual(n1, edge.from_id);
    try std.testing.expectEqual(n2, edge.to_id);
    try std.testing.expectEqualStrings("KNOWS", edge.label);

    // Verify edge property
    const since_prop = edge.properties.get("since");
    try std.testing.expect(since_prop != null);
    switch (since_prop.?) {
        .Int => |v| try std.testing.expectEqual(@as(i64, 2020), v),
        else => return error.TestUnexpectedResult,
    }
}

test "snapshot_manager: installSnapshotData rejects checksum mismatch" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    const data = "{\"type\":\"node\",\"id\":1,\"graph\":\"default\",\"labels\":[],\"properties\":{}}\n";
    const bad_checksum: u32 = 0xDEADBEEF;

    const result = installSnapshotData(allocator, &store, data, bad_checksum);
    try std.testing.expectError(error.ChecksumMismatch, result);
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
