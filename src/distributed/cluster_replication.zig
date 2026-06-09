// Cluster write replication payload codec + deterministic apply.
//
// Root cause #2 of docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md:
// graph writes bypassed Raft entirely, so they never replicated. This module is
// the deterministic state-machine slice that closes that gap for the common
// node-CREATE case:
//
//   * On the LEADER, the executor serializes a simple `CREATE (:L {literal})`
//     into a self-describing payload and proposes it to Raft (it does NOT write
//     locally). See crud_operations.tryClusterReplicateCreate.
//   * On EVERY node (leader + followers), the Raft apply callback decodes the
//     payload and replays it via the store's normal create/setProperty path.
//     The replicated node's id is derived from the committed entry's Raft log
//     index, which is globally unique and IDENTICAL on every node (Raft Log
//     Matching Property). This makes apply BOTH cross-node deterministic (all
//     nodes mint the same id for a given committed entry) AND restart-idempotent
//     (re-applying a committed entry hits an id that already exists in the
//     persisted store → `error.NodeAlreadyExists` → no-op, no duplicate row).
//     The persisted graph store is the dedup oracle.
//
// Only literal-valued single-node creates are encoded here; anything else falls
// back to the existing (single-node) local path in the executor, so this is a
// strict superset of prior behavior and cannot regress single-node writes.
//
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-CREATE; FEATURE="DistributedCluster"; ASPECT=WriteReplicationNodeCreate; STATUS=TESTED; TEST=tests/test_cluster_3node_steady_state.zig; OWNER=distributed; UPDATED=2026-06-04

const std = @import("std");
const graph_store = @import("../graph_store.zig");
const PropertyValue = graph_store.PropertyValue;
const GraphStore = graph_store.GraphStore;

/// 4-byte magic prefix identifying a node-create payload in GraphMutation.data.
/// (Legacy/MVP `_raft_data` payloads have no magic and take the fallback path.)
pub const MAGIC = [4]u8{ 'G', 'N', 'C', '1' };

pub const Prop = struct { key: []const u8, value: PropertyValue };

pub const CodecError = error{ UnsupportedPropertyType, CorruptPayload };

fn appendU16(list: *std.ArrayList(u8), a: std.mem.Allocator, v: usize) !void {
    if (v > std.math.maxInt(u16)) return CodecError.UnsupportedPropertyType;
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, @intCast(v), .little);
    try list.appendSlice(a, &b);
}

fn appendU32(list: *std.ArrayList(u8), a: std.mem.Allocator, v: usize) !void {
    if (v > std.math.maxInt(u32)) return CodecError.UnsupportedPropertyType;
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @intCast(v), .little);
    try list.appendSlice(a, &b);
}

fn appendStr16(list: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try appendU16(list, a, s.len);
    try list.appendSlice(a, s);
}

/// Serialize a single-node create. `props` values must be one of the supported
/// scalar types (Int/Float/Bool/String/Null); anything else returns
/// `error.UnsupportedPropertyType` and the caller falls back to local execution.
pub fn serializeNodeCreate(
    allocator: std.mem.Allocator,
    graph: []const u8,
    labels: []const []const u8,
    props: []const Prop,
) ![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);

    try list.appendSlice(allocator, &MAGIC);
    try appendStr16(&list, allocator, graph);
    try appendU16(&list, allocator, labels.len);
    for (labels) |l| try appendStr16(&list, allocator, l);
    try appendU16(&list, allocator, props.len);
    for (props) |p| {
        try appendStr16(&list, allocator, p.key);
        switch (p.value) {
            .Null => try list.append(allocator, 0),
            .Int => |i| {
                try list.append(allocator, 1);
                var b: [8]u8 = undefined;
                std.mem.writeInt(i64, &b, i, .little);
                try list.appendSlice(allocator, &b);
            },
            .Float => |f| {
                try list.append(allocator, 2);
                var b: [8]u8 = undefined;
                std.mem.writeInt(u64, &b, @bitCast(f), .little);
                try list.appendSlice(allocator, &b);
            },
            .Bool => |bo| {
                try list.append(allocator, 3);
                try list.append(allocator, if (bo) 1 else 0);
            },
            .String => |s| {
                try list.append(allocator, 4);
                try appendU32(&list, allocator, s.len);
                try list.appendSlice(allocator, s);
            },
            else => return CodecError.UnsupportedPropertyType,
        }
    }
    return list.toOwnedSlice(allocator);
}

pub fn isNodeCreatePayload(data: []const u8) bool {
    return data.len >= MAGIC.len and std.mem.eql(u8, data[0..MAGIC.len], &MAGIC);
}

const Reader = struct {
    data: []const u8,
    pos: usize,

    fn readU16(self: *Reader) !u16 {
        if (self.pos + 2 > self.data.len) return CodecError.CorruptPayload;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }
    fn readU32(self: *Reader) !u32 {
        if (self.pos + 4 > self.data.len) return CodecError.CorruptPayload;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    fn readI64(self: *Reader) !i64 {
        if (self.pos + 8 > self.data.len) return CodecError.CorruptPayload;
        const v = std.mem.readInt(i64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }
    fn readU64(self: *Reader) !u64 {
        if (self.pos + 8 > self.data.len) return CodecError.CorruptPayload;
        const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }
    fn byte(self: *Reader) !u8 {
        if (self.pos + 1 > self.data.len) return CodecError.CorruptPayload;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }
    fn str16(self: *Reader) ![]const u8 {
        const n = try self.readU16();
        if (self.pos + n > self.data.len) return CodecError.CorruptPayload;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
    fn str32(self: *Reader) ![]const u8 {
        const n = try self.readU32();
        if (self.pos + n > self.data.len) return CodecError.CorruptPayload;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
};

/// Deterministically apply a node-create payload to `store`, using `node_id`
/// (the committed Raft log index) as the node's id. Used by the Raft apply
/// callback on every node. The store deep-copies labels/keys/values, so the
/// borrowed slices into `data` (a transient committed log entry) are safe.
///
/// Idempotent: if the node id already exists in the persisted store (a restarted
/// node replaying a committed entry on top of its persisted graph), the create
/// is a no-op and the property writes idempotently overwrite — which also
/// repairs a partial first-apply that created the node but crashed mid-props.
/// Returns the node id.
pub fn applyNodeCreatePayload(allocator: std.mem.Allocator, store: *GraphStore, data: []const u8, node_id: u64) !u64 {
    if (!isNodeCreatePayload(data)) return CodecError.CorruptPayload;
    var r = Reader{ .data = data, .pos = MAGIC.len };

    const graph = try r.str16();
    store.createGraph(graph) catch |err| switch (err) {
        error.GraphAlreadyExists => {},
        else => return err,
    };

    const nlabels = try r.readU16();
    var labels = std.ArrayList([]const u8).empty;
    defer labels.deinit(allocator);
    var li: usize = 0;
    while (li < nlabels) : (li += 1) try labels.append(allocator, try r.str16());

    store.createNodeWithId(node_id, labels.items, graph) catch |err| switch (err) {
        // Already created by a prior apply of THIS committed entry — idempotent.
        error.NodeAlreadyExists => {},
        else => return err,
    };

    const nprops = try r.readU16();
    var pi: usize = 0;
    while (pi < nprops) : (pi += 1) {
        const key = try r.str16();
        const tag = try r.byte();
        const val: PropertyValue = switch (tag) {
            0 => .Null,
            1 => .{ .Int = try r.readI64() },
            2 => .{ .Float = @bitCast(try r.readU64()) },
            3 => .{ .Bool = (try r.byte()) != 0 },
            4 => .{ .String = try r.str32() },
            else => return CodecError.CorruptPayload,
        };
        try store.setNodeProperty(node_id, key, val);
    }
    return node_id;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "node-create payload round-trips through serialize -> apply" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    const labels = [_][]const u8{"ReplTest"};
    const props = [_]Prop{
        .{ .key = "v", .value = .{ .Int = 42 } },
        .{ .key = "name", .value = .{ .String = "alice" } },
        .{ .key = "active", .value = .{ .Bool = true } },
        .{ .key = "score", .value = .{ .Float = 1.5 } },
        .{ .key = "note", .value = .Null },
    };
    const payload = try serializeNodeCreate(a, "g1", &labels, &props);
    defer a.free(payload);

    try std.testing.expect(isNodeCreatePayload(payload));

    const node_id = try applyNodeCreatePayload(a, &store, payload, 7);
    try std.testing.expectEqual(@as(u64, 7), node_id);
    try std.testing.expect(store.graphs.contains("g1"));

    // The node carries the replicated properties.
    try std.testing.expectEqual(@as(i64, 42), (store.getNodeProperty(node_id, "v").?).Int);
    try std.testing.expectEqualStrings("alice", (store.getNodeProperty(node_id, "name").?).String);
    try std.testing.expectEqual(true, (store.getNodeProperty(node_id, "active").?).Bool);
}

test "two committed entries get deterministic raft-index-derived ids on every node" {
    const a = std.testing.allocator;
    var s1 = try GraphStore.init(a);
    defer s1.deinit();
    var s2 = try GraphStore.init(a);
    defer s2.deinit();

    const labels = [_][]const u8{"N"};
    const p0 = try serializeNodeCreate(a, "default", &labels, &.{});
    defer a.free(p0);
    const p1 = try serializeNodeCreate(a, "default", &labels, &.{});
    defer a.free(p1);

    // The committed log indices are identical on every node (Log Matching
    // Property), so each node mints the SAME id for a given committed entry —
    // and that id IS the raft index.
    const a0 = try applyNodeCreatePayload(a, &s1, p0, 5);
    const a1 = try applyNodeCreatePayload(a, &s1, p1, 6);
    const b0 = try applyNodeCreatePayload(a, &s2, p0, 5);
    const b1 = try applyNodeCreatePayload(a, &s2, p1, 6);
    try std.testing.expectEqual(a0, b0);
    try std.testing.expectEqual(a1, b1);
    try std.testing.expectEqual(@as(u64, 5), a0);
    try std.testing.expectEqual(@as(u64, 6), a1);
    try std.testing.expect(a1 != a0);
}

test "unsupported property type is rejected at serialize time" {
    const a = std.testing.allocator;
    const labels = [_][]const u8{"N"};
    const props = [_]Prop{.{ .key = "d", .value = .{ .Decimal = .{ .coeff = 1, .scale = 0 } } }};
    try std.testing.expectError(CodecError.UnsupportedPropertyType, serializeNodeCreate(a, "g", &labels, &props));
}

test "truncated payload is rejected, not crashed" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();
    const labels = [_][]const u8{"N"};
    const full = try serializeNodeCreate(a, "g", &labels, &.{.{ .key = "k", .value = .{ .Int = 1 } }});
    defer a.free(full);
    try std.testing.expectError(CodecError.CorruptPayload, applyNodeCreatePayload(a, &store, full[0 .. full.len - 3], 1));
}
