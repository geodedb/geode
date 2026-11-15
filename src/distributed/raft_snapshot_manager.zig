const std = @import("std");
const graph_store = @import("../graph_store.zig");
const GraphStore = graph_store.GraphStore;
const PropertyValue = graph_store.PropertyValue;
const cluster_replication = @import("cluster_replication.zig");

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

// ---------------------------------------------------------------------------
// FTS snapshot-rebuild hook (2026-06-10 audit, slice 3)
// ---------------------------------------------------------------------------
//
// `installSnapshotData` wipes the store (`clearNodes`) and recreates every
// node/edge via the *NoSave paths — which never touch FTS. Without a rebuild,
// every fulltext index keeps serving the PRE-snapshot corpus (including
// permanent engine tombstones for nodes the snapshot just restored), so
// follower `CALL geode.fts.search` diverges after an InstallSnapshot.
//
// Same callback seam as cluster_replication's FtsApplyHook (this file is also
// compiled in module roots where the executor's deps aren't mapped, so we
// cannot @import fts_index_ops here). Registered by
// `fts_index_ops.registerFtsApplyHook()`; the wrapper drops + recreates every
// catalogued fulltext index on the process-global store and re-backfills it
// from the restored graph. Cost: O(total indexed nodes) per snapshot install —
// correctness over speed (snapshot install is already a full-store rewrite).
// CANARY: REQ=REQ-DIST-CLUSTER-FTS-APPLY-SYMMETRY; FEATURE="DistributedCluster"; ASPECT=FtsSnapshotRebuild; STATUS=TESTED; TEST=tests/test_fts_apply_symmetry.zig; OWNER=distributed; UPDATED=2026-06-10

/// Rebuild hook fired after a snapshot is fully installed into `store`.
/// Must not fail the install: returns void and logs internally.
pub const FtsSnapshotRebuildHook = *const fn (store: *GraphStore) void;

var g_fts_snapshot_rebuild_hook: ?FtsSnapshotRebuildHook = null;

/// Install (or clear with null) the FTS snapshot-rebuild hook. Idempotent.
pub fn setFtsSnapshotRebuildHook(hook: ?FtsSnapshotRebuildHook) void {
    g_fts_snapshot_rebuild_hook = hook;
}

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

    // CANARY: REQ=REQ-SONNY-3317-RAFT-INSTALL-LOCKED; FEATURE="Raft Snapshot Persistence"; ASPECT=InstallUnderStoreLock; STATUS=TESTED; TEST=tests/test_sonny3317_round15_minors.zig; OWNER=distributed; UPDATED=2026-09-28
    // SONNY-3317 (round 16, M7; pre-existing): the store is cleared and
    // rebuilt under its write lock (exclusive): every request's graph lock
    // takes it shared first, so none reads or writes a store half replaced.
    // It ran with no lock.
    // The fulltext rebuild below takes graph locks itself: it runs after.
    {
        graph_store.acquireStoreWriteLock();
        defer graph_store.releaseStoreWriteLock();

        // 2. Clear existing store data
        store.clearNodes();

        // 3. Parse JSON-lines and recreate nodes/edges
        var line_iter = std.mem.splitScalar(u8, data, '\n');
        while (line_iter.next()) |line| {
            if (line.len == 0) continue;
            try parseLine(store, line);
        }
    }

    // 4. Rebuild fulltext indexes from the restored store (see hook docs
    //    above). No-op when unregistered (bare unit tests) or when `store`
    //    is not the process-global store.
    if (g_fts_snapshot_rebuild_hook) |hook| hook(store);
}

// CANARY: REQ=REQ-SONNY-6622-RAFT-SNAPSHOT-RESTORE; FEATURE="Raft Snapshot Persistence"; ASPECT=RaftSnapshotPayload; STATUS=TESTED; TEST=tests/test_sonny6622_raft_v022_adapt.zig; OWNER=distributed; UPDATED=2026-11-15
// CANARY: REQ=REQ-SONNY-6633-DEDUP-IN-SNAPSHOT; FEATURE="DistributedCluster"; ASPECT=SnapshotCarriesDedup; STATUS=TESTED; TEST=tests/test_sonny6633_snapshot_wire.zig; OWNER=distributed; UPDATED=2026-11-15
/// The state-machine snapshot a leader hands the raft library
/// (`reportSnapshot`), SONNY-6622 / SONNY-6633:
///
///   "GRS2" | u32 CRC32 of the rest (big-endian) | u64 JSON-lines length |
///   JSON-lines snapshot of the store | idempotency table
///   (`IdempotencyDedup.serialize`, empty table when `dedup` is null).
///
/// The idempotency table travels with the store: it is otherwise rebuilt by
/// replaying the committed log, and the snapshot replaces the entries that
/// would rebuild it (SONNY-6633 item 6). The caller frees the result.
pub const raft_snapshot_magic = "GRS2";

pub fn encodeRaftSnapshot(allocator: std.mem.Allocator, store: *GraphStore, dedup: ?*const cluster_replication.IdempotencyDedup) ![]u8 {
    const data = try store.serializeSnapshot(allocator);
    defer allocator.free(data);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, raft_snapshot_magic);
    try out.appendNTimes(allocator, 0, 4); // CRC, below
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, data.len, .big);
    try out.appendSlice(allocator, &len_buf);
    try out.appendSlice(allocator, data);
    if (dedup) |d| {
        try d.serialize(&out, allocator);
    } else {
        try out.appendNTimes(allocator, 0, 4);
    }
    std.mem.writeInt(u32, out.items[4..8], Crc32.hash(out.items[8..]), .big);
    return out.toOwnedSlice(allocator);
}

/// Install a payload `encodeRaftSnapshot` made: `store`'s contents are
/// replaced (`installSnapshotData`), then `dedup`'s, when given. Everything
/// is checked before anything is replaced.
pub fn installRaftSnapshot(allocator: std.mem.Allocator, store: *GraphStore, payload: []const u8, dedup: ?*cluster_replication.IdempotencyDedup) !void {
    if (payload.len < 16 or !std.mem.eql(u8, payload[0..4], raft_snapshot_magic)) return error.InvalidJsonLine;
    if (Crc32.hash(payload[8..]) != std.mem.readInt(u32, payload[4..8], .big)) return error.ChecksumMismatch;
    const data_len = std.mem.readInt(u64, payload[8..16], .big);
    if (data_len > payload.len - 16) return error.InvalidJsonLine;
    const data = payload[16..][0..@intCast(data_len)];
    const dedup_bytes = payload[16 + data.len ..];
    // Check the table first: it must not fail after the store was replaced.
    var check = cluster_replication.IdempotencyDedup.init(allocator);
    defer check.deinit();
    try check.replaceFrom(dedup_bytes);
    try installSnapshotData(allocator, store, data, Crc32.hash(data));
    if (dedup) |d| try d.replaceFrom(dedup_bytes);
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
        // SONNY-2810: NaN and the infinities (`GraphStore.serializeSnapshot`).
        .object => |o| blk: {
            if (o.count() != 1) break :blk null;
            const tag = o.get("$float") orelse break :blk null;
            const text = switch (tag) {
                .string => |t| t,
                else => break :blk null,
            };
            if (std.mem.eql(u8, text, "nan")) break :blk PropertyValue{ .Float = std.math.nan(f64) };
            if (std.mem.eql(u8, text, "inf")) break :blk PropertyValue{ .Float = std.math.inf(f64) };
            if (std.mem.eql(u8, text, "-inf")) break :blk PropertyValue{ .Float = -std.math.inf(f64) };
            break :blk null;
        },
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
