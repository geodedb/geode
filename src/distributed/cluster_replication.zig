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

// ===========================================================================
// GNC2 — deterministic MULTI-id create (nodes + edges from one committed entry)
// ===========================================================================
//
// Slice A of the cluster-replication fix: a single committed Raft entry must be
// able to mint up to N nodes + M edges (the EDGE CREATE case
// `CREATE (a)-[:R]->(b)` = 2 nodes + 1 edge). GNC1 keyed the lone node id off
// the raft index directly; GNC2 needs MANY ids from one index, so it derives
// them positionally from the (globally-unique, cross-node-identical) raft index.
//
// ID BANDS (documented + sweep-tested in `id-band collision sweep`):
//
//   * GNC1 single-node id  = raft_index                         (commit 78439d6f)
//   * GNC2 node lane (k)   = MULTI_ID_BASE + raft_index*64 + k         (k 0..31)
//   * GNC2 edge lane (j)   = MULTI_ID_BASE + raft_index*64 + 32 + j    (j 0..31)
//
// Why MULTI_ID_BASE = 1<<40:
//   - DISJOINT from GNC1 ids: a plain raft index is realistically < ~1e9 (≈2^30),
//     far below 2^40, so GNC2's band can never alias a GNC1 id minted at any
//     other index. (Without the base offset, raft_index*64 = 128 would collide
//     with a plain GNC1 index 128 — the exact hazard called out in the design.)
//   - FAR BELOW the time-based id floor: graph_store.generateTimeBasedId encodes
//     `now_ms << 16`; for 2026 (now_ms ≈ 1.78e12) that floor is ≈ 1.17e17 ≈ 2^56.7.
//     For raft_index < 2^47, raft_index*64 < 2^53, so the largest GNC2 id is
//     < 2^40 + 2^53 + 64 ≈ 9.0e15 (≈ 2^53), comfortably below the 2^56.7 floor —
//     a GNC2 id can never alias a future time-based node id either.
//   - The 64-wide stride per index (32 node lanes + 32 edge lanes) makes lanes of
//     DIFFERENT indices disjoint (index i uses [base+i*64, base+i*64+63]).
//
// Cap: N,M ≤ 32 per entry (the lane width). Rejected at serialize time.
//
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-EDGE-CREATE; FEATURE="DistributedCluster"; ASPECT=MultiIdDerivation; STATUS=TESTED; TEST=tests/test_raft_apply_restart_idempotent.zig; OWNER=distributed; UPDATED=2026-06-09

/// 4-byte magic prefix identifying a GNC2 multi-create payload.
pub const MAGIC2 = [4]u8{ 'G', 'N', 'C', '2' };

/// Offset that lifts the GNC2 id band clear of plain raft indices (GNC1 ids).
/// See the band documentation above. 1<<40 ≈ 1.1e12.
pub const MULTI_ID_BASE: u64 = 1 << 40;

/// Lane stride per committed entry: 32 node lanes [0..31] + 32 edge lanes [0..31].
pub const MULTI_LANE_STRIDE: u64 = 64;

/// Max nodes (or edges) a single GNC2 entry may mint (the lane width).
pub const MAX_MULTI_NODES: usize = 32;
pub const MAX_MULTI_EDGES: usize = 32;

/// Deterministic id for node position `k` (0-based) in the entry committed at
/// `raft_index`. Identical on every node; restart-idempotent; collision-free.
pub fn deriveMultiNodeId(raft_index: u64, k: usize) u64 {
    std.debug.assert(k < MAX_MULTI_NODES);
    return MULTI_ID_BASE + raft_index * MULTI_LANE_STRIDE + @as(u64, @intCast(k));
}

/// Deterministic id for edge position `j` (0-based) in the entry committed at
/// `raft_index`. Lives in the upper half of the per-index lane window.
pub fn deriveMultiEdgeId(raft_index: u64, j: usize) u64 {
    std.debug.assert(j < MAX_MULTI_EDGES);
    return MULTI_ID_BASE + raft_index * MULTI_LANE_STRIDE + MAX_MULTI_NODES + @as(u64, @intCast(j));
}

pub fn isMultiCreatePayload(data: []const u8) bool {
    return data.len >= MAGIC2.len and std.mem.eql(u8, data[0..MAGIC2.len], &MAGIC2);
}

/// An edge endpoint in a GNC2 payload. `position` references a node CREATED in
/// THIS entry (0-based index into the node-spec list — required for the target
/// EDGE CREATE test). `absolute_id` references a PRE-EXISTING node by its stable
/// store id (needed later by MERGE-rel; cheap to encode now).
pub const Endpoint = union(enum) {
    position: u32,
    absolute_id: u64,
};

/// A node to create in a GNC2 entry: its labels + scalar props.
pub const NodeSpec = struct { labels: []const []const u8, props: []const Prop };

/// An edge to create in a GNC2 entry: endpoints + type + scalar props.
pub const EdgeSpec = struct {
    from: Endpoint,
    to: Endpoint,
    edge_type: []const u8,
    props: []const Prop,
};

fn appendProps(list: *std.ArrayList(u8), a: std.mem.Allocator, props: []const Prop) !void {
    try appendU16(list, a, props.len);
    for (props) |p| {
        try appendStr16(list, a, p.key);
        switch (p.value) {
            .Null => try list.append(a, 0),
            .Int => |i| {
                try list.append(a, 1);
                var b: [8]u8 = undefined;
                std.mem.writeInt(i64, &b, i, .little);
                try list.appendSlice(a, &b);
            },
            .Float => |f| {
                try list.append(a, 2);
                var b: [8]u8 = undefined;
                std.mem.writeInt(u64, &b, @bitCast(f), .little);
                try list.appendSlice(a, &b);
            },
            .Bool => |bo| {
                try list.append(a, 3);
                try list.append(a, if (bo) 1 else 0);
            },
            .String => |s| {
                try list.append(a, 4);
                try appendU32(list, a, s.len);
                try list.appendSlice(a, s);
            },
            else => return CodecError.UnsupportedPropertyType,
        }
    }
}

fn appendEndpoint(list: *std.ArrayList(u8), a: std.mem.Allocator, ep: Endpoint) !void {
    switch (ep) {
        .position => |p| {
            try list.append(a, 0); // tag 0 = positional
            try appendU16(list, a, p);
        },
        .absolute_id => |id| {
            try list.append(a, 1); // tag 1 = absolute id
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, id, .little);
            try list.appendSlice(a, &b);
        },
    }
}

/// Serialize a multi-create (N nodes + M edges) into a self-describing GNC2
/// payload. All property values must be supported scalars; an edge endpoint may
/// reference a node created in this entry (`.position`) or a pre-existing node
/// (`.absolute_id`). Rejects (fail-closed) more than `MAX_MULTI_*` of either, or
/// any positional endpoint that is out of range, so the caller never proposes a
/// payload that cannot be applied deterministically.
pub fn serializeMultiCreate(
    allocator: std.mem.Allocator,
    graph: []const u8,
    nodes: []const NodeSpec,
    edges: []const EdgeSpec,
) ![]u8 {
    if (nodes.len > MAX_MULTI_NODES or edges.len > MAX_MULTI_EDGES)
        return CodecError.UnsupportedPropertyType;

    // Validate positional endpoints up front (an out-of-range position would be
    // un-applyable). Absolute-id endpoints are validated at apply time (the
    // referenced node must already exist in the store).
    for (edges) |e| {
        if (e.from == .position and e.from.position >= nodes.len)
            return CodecError.CorruptPayload;
        if (e.to == .position and e.to.position >= nodes.len)
            return CodecError.CorruptPayload;
    }

    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);

    try list.appendSlice(allocator, &MAGIC2);
    try appendStr16(&list, allocator, graph);

    try appendU16(&list, allocator, nodes.len);
    for (nodes) |n| {
        try appendU16(&list, allocator, n.labels.len);
        for (n.labels) |l| try appendStr16(&list, allocator, l);
        try appendProps(&list, allocator, n.props);
    }

    try appendU16(&list, allocator, edges.len);
    for (edges) |e| {
        try appendEndpoint(&list, allocator, e.from);
        try appendEndpoint(&list, allocator, e.to);
        try appendStr16(&list, allocator, e.edge_type);
        try appendProps(&list, allocator, e.props);
    }

    return list.toOwnedSlice(allocator);
}

fn readProp(r: *Reader) !Prop {
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
    return .{ .key = key, .value = val };
}

fn readEndpoint(r: *Reader) !Endpoint {
    const tag = try r.byte();
    return switch (tag) {
        0 => .{ .position = try r.readU16() },
        1 => .{ .absolute_id = try r.readU64() },
        else => CodecError.CorruptPayload,
    };
}

/// Deterministically apply a GNC2 multi-create payload to `store`, deriving all
/// node/edge ids positionally from `raft_index` (so apply is cross-node
/// identical AND restart-idempotent — re-applying a committed entry hits ids
/// that already exist and is a no-op). Endpoints resolve to either a
/// just-derived node id (`.position`) or a pre-existing store id
/// (`.absolute_id`). Returns the number of nodes + edges created/touched.
pub fn applyMultiCreatePayload(
    allocator: std.mem.Allocator,
    store: *GraphStore,
    data: []const u8,
    raft_index: u64,
) !usize {
    if (!isMultiCreatePayload(data)) return CodecError.CorruptPayload;
    var r = Reader{ .data = data, .pos = MAGIC2.len };

    const graph = try r.str16();
    store.createGraph(graph) catch |err| switch (err) {
        error.GraphAlreadyExists => {},
        else => return err,
    };

    const node_count = try r.readU16();
    if (node_count > MAX_MULTI_NODES) return CodecError.CorruptPayload;

    var labels = std.ArrayList([]const u8).empty;
    defer labels.deinit(allocator);

    var k: usize = 0;
    while (k < node_count) : (k += 1) {
        const node_id = deriveMultiNodeId(raft_index, k);

        labels.clearRetainingCapacity();
        const nlabels = try r.readU16();
        var li: usize = 0;
        while (li < nlabels) : (li += 1) try labels.append(allocator, try r.str16());

        store.createNodeWithId(node_id, labels.items, graph) catch |err| switch (err) {
            error.NodeAlreadyExists => {}, // idempotent re-apply
            else => return err,
        };

        const nprops = try r.readU16();
        var pi: usize = 0;
        while (pi < nprops) : (pi += 1) {
            const p = try readProp(&r);
            try store.setNodeProperty(node_id, p.key, p.value);
        }
    }

    const edge_count = try r.readU16();
    if (edge_count > MAX_MULTI_EDGES) return CodecError.CorruptPayload;

    var j: usize = 0;
    while (j < edge_count) : (j += 1) {
        const from_ep = try readEndpoint(&r);
        const to_ep = try readEndpoint(&r);
        const edge_type = try r.str16();
        const nprops = try r.readU16();

        const from_id = resolveEndpoint(from_ep, raft_index, node_count) orelse return CodecError.CorruptPayload;
        const to_id = resolveEndpoint(to_ep, raft_index, node_count) orelse return CodecError.CorruptPayload;
        const edge_id = deriveMultiEdgeId(raft_index, j);

        store.createEdgeWithId(edge_id, from_id, to_id, edge_type, graph) catch |err| switch (err) {
            error.EdgeAlreadyExists => {}, // idempotent re-apply
            else => return err,
        };

        var pi: usize = 0;
        while (pi < nprops) : (pi += 1) {
            const p = try readProp(&r);
            // Idempotent: setEdgeProperty no-ops if the edge is absent and
            // overwrites in place otherwise (repairs a partial first-apply).
            try store.setEdgeProperty(edge_id, p.key, p.value);
        }
    }

    return @as(usize, node_count) + @as(usize, edge_count);
}

fn resolveEndpoint(ep: Endpoint, raft_index: u64, node_count: u16) ?u64 {
    return switch (ep) {
        .position => |p| if (p < node_count) deriveMultiNodeId(raft_index, p) else null,
        .absolute_id => |id| id,
    };
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

// ---------------------------------------------------------------------------
// GNC2 multi-create tests
// ---------------------------------------------------------------------------

test "GNC2 edge-create round-trips: 2 nodes + 1 positional edge" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    const la = [_][]const u8{"EdgeRepl"};
    const lb = [_][]const u8{"EdgeRepl"};
    const nodes = [_]NodeSpec{
        .{ .labels = &la, .props = &.{.{ .key = "k", .value = .{ .Int = 1 } }} },
        .{ .labels = &lb, .props = &.{.{ .key = "k", .value = .{ .Int = 2 } }} },
    };
    const edges = [_]EdgeSpec{
        .{ .from = .{ .position = 0 }, .to = .{ .position = 1 }, .edge_type = "LINKS", .props = &.{} },
    };
    const payload = try serializeMultiCreate(a, "default", &nodes, &edges);
    defer a.free(payload);
    try std.testing.expect(isMultiCreatePayload(payload));

    const touched = try applyMultiCreatePayload(a, &store, payload, 10);
    try std.testing.expectEqual(@as(usize, 3), touched); // 2 nodes + 1 edge

    // Exactly 2 nodes, 1 edge.
    try std.testing.expectEqual(@as(usize, 2), store.countNodesByLabel("default", "EdgeRepl", null));
    try std.testing.expectEqual(@as(usize, 1), store.edges.count());

    // Endpoints resolved to the derived node ids; props landed.
    const n0 = deriveMultiNodeId(10, 0);
    const n1 = deriveMultiNodeId(10, 1);
    const e0 = deriveMultiEdgeId(10, 0);
    try std.testing.expectEqual(@as(i64, 1), store.getNodeProperty(n0, "k").?.Int);
    try std.testing.expectEqual(@as(i64, 2), store.getNodeProperty(n1, "k").?.Int);
    const edge = store.edges.get(e0).?;
    try std.testing.expectEqual(n0, edge.from_id);
    try std.testing.expectEqual(n1, edge.to_id);
    try std.testing.expectEqualStrings("LINKS", edge.label);
}

test "GNC2 apply is idempotent: re-applying same raft index leaves 2 nodes + 1 edge" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    const la = [_][]const u8{"M"};
    const nodes = [_]NodeSpec{
        .{ .labels = &la, .props = &.{} },
        .{ .labels = &la, .props = &.{} },
    };
    const edges = [_]EdgeSpec{
        .{ .from = .{ .position = 0 }, .to = .{ .position = 1 }, .edge_type = "R", .props = &.{} },
    };
    const payload = try serializeMultiCreate(a, "default", &nodes, &edges);
    defer a.free(payload);

    _ = try applyMultiCreatePayload(a, &store, payload, 7);
    _ = try applyMultiCreatePayload(a, &store, payload, 7); // restart replay

    try std.testing.expectEqual(@as(usize, 2), store.countNodesByLabel("default", "M", null));
    try std.testing.expectEqual(@as(usize, 1), store.edges.count());
}

test "GNC2 two stores apply same payload sequence -> identical ids" {
    const a = std.testing.allocator;
    var s1 = try GraphStore.init(a);
    defer s1.deinit();
    var s2 = try GraphStore.init(a);
    defer s2.deinit();

    const la = [_][]const u8{"X"};
    const nodes = [_]NodeSpec{ .{ .labels = &la, .props = &.{} }, .{ .labels = &la, .props = &.{} } };
    const edges = [_]EdgeSpec{
        .{ .from = .{ .position = 0 }, .to = .{ .position = 1 }, .edge_type = "R", .props = &.{} },
    };
    const payload = try serializeMultiCreate(a, "default", &nodes, &edges);
    defer a.free(payload);

    _ = try applyMultiCreatePayload(a, &s1, payload, 99);
    _ = try applyMultiCreatePayload(a, &s2, payload, 99);

    // Both stores minted the same derived ids (Log Matching Property).
    const n0 = deriveMultiNodeId(99, 0);
    const n1 = deriveMultiNodeId(99, 1);
    const e0 = deriveMultiEdgeId(99, 0);
    try std.testing.expect(s1.nodes.contains(n0) and s2.nodes.contains(n0));
    try std.testing.expect(s1.nodes.contains(n1) and s2.nodes.contains(n1));
    try std.testing.expect(s1.edges.contains(e0) and s2.edges.contains(e0));
}

test "GNC2 edge endpoint absolute-id variant references a pre-existing node" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    // Pre-existing anchor node at a stable id (as a prior GNC1 entry would mint).
    try store.createNodeWithId(42, &.{"Anchor"}, "default");

    // One new node, one edge from the new node to the pre-existing anchor.
    const la = [_][]const u8{"New"};
    const nodes = [_]NodeSpec{.{ .labels = &la, .props = &.{} }};
    const edges = [_]EdgeSpec{
        .{ .from = .{ .position = 0 }, .to = .{ .absolute_id = 42 }, .edge_type = "TO_ANCHOR", .props = &.{} },
    };
    const payload = try serializeMultiCreate(a, "default", &nodes, &edges);
    defer a.free(payload);

    _ = try applyMultiCreatePayload(a, &store, payload, 5);

    const e0 = deriveMultiEdgeId(5, 0);
    const n0 = deriveMultiNodeId(5, 0);
    const edge = store.edges.get(e0).?;
    try std.testing.expectEqual(n0, edge.from_id);
    try std.testing.expectEqual(@as(u64, 42), edge.to_id);
}

test "GNC2 edge props round-trip" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    const la = [_][]const u8{"W"};
    const nodes = [_]NodeSpec{ .{ .labels = &la, .props = &.{} }, .{ .labels = &la, .props = &.{} } };
    const edges = [_]EdgeSpec{
        .{ .from = .{ .position = 0 }, .to = .{ .position = 1 }, .edge_type = "WEIGHTED", .props = &.{
            .{ .key = "w", .value = .{ .Int = 7 } },
        } },
    };
    const payload = try serializeMultiCreate(a, "default", &nodes, &edges);
    defer a.free(payload);

    _ = try applyMultiCreatePayload(a, &store, payload, 3);
    const e0 = deriveMultiEdgeId(3, 0);
    const edge = store.edges.get(e0).?;
    try std.testing.expectEqual(@as(i64, 7), edge.properties.get("w").?.Int);
}

test "GNC2 rejects >32 nodes/edges and out-of-range positional endpoint" {
    const a = std.testing.allocator;

    // 33 nodes — over the lane cap.
    var many: [33]NodeSpec = undefined;
    const la = [_][]const u8{"L"};
    for (&many) |*n| n.* = .{ .labels = &la, .props = &.{} };
    try std.testing.expectError(CodecError.UnsupportedPropertyType, serializeMultiCreate(a, "default", &many, &.{}));

    // Positional endpoint out of range (only 1 node, edge references position 5).
    const nodes = [_]NodeSpec{.{ .labels = &la, .props = &.{} }};
    const edges = [_]EdgeSpec{
        .{ .from = .{ .position = 0 }, .to = .{ .position = 5 }, .edge_type = "R", .props = &.{} },
    };
    try std.testing.expectError(CodecError.CorruptPayload, serializeMultiCreate(a, "default", &nodes, &edges));
}

test "GNC2 truncated payload is rejected, not crashed" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();
    const la = [_][]const u8{"T"};
    const nodes = [_]NodeSpec{ .{ .labels = &la, .props = &.{} }, .{ .labels = &la, .props = &.{} } };
    const edges = [_]EdgeSpec{
        .{ .from = .{ .position = 0 }, .to = .{ .position = 1 }, .edge_type = "R", .props = &.{} },
    };
    const full = try serializeMultiCreate(a, "default", &nodes, &edges);
    defer a.free(full);
    try std.testing.expectError(CodecError.CorruptPayload, applyMultiCreatePayload(a, &store, full[0 .. full.len - 3], 1));
}

// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-EDGE-CREATE; FEATURE="DistributedCluster"; ASPECT=IdBandCollisionSweep; STATUS=TESTED; TEST=tests/test_raft_apply.zig; OWNER=distributed; UPDATED=2026-06-09
test "GNC2 id-band sweep: no GNC1/GNC2 collision, no lane overlap, below time floor" {
    // (a) No GNC2-derived id ever equals a plain GNC1 id (raft_index') for any
    //     pair of indices in a large realistic range.
    // (b) Node and edge lanes never overlap across indices.
    // (c) Every derived id stays below the time-based id floor.
    //
    // The time-based floor for the CURRENT era (graph_store.generateTimeBasedId
    // encodes now_ms << 16). We use a conservative lower bound on now_ms for any
    // realistic deploy date: 1.5e12 ms ≈ 2017-07. floor = 1.5e12 << 16 ≈ 9.8e16.
    const time_floor: u64 = @as(u64, 1_500_000_000_000) << 16;

    // Realistic raft index range. Plain GNC1 ids are exactly these values.
    const max_index: u64 = 200_000;

    var idx: u64 = 1;
    while (idx <= max_index) : (idx += 1) {
        // Node + edge lanes for this index occupy a single 64-wide window.
        var k: usize = 0;
        while (k < MAX_MULTI_NODES) : (k += 1) {
            const nid = deriveMultiNodeId(idx, k);
            try std.testing.expect(nid >= MULTI_ID_BASE); // (a) above any plain index
            try std.testing.expect(nid < time_floor); // (c)
        }
        var j: usize = 0;
        while (j < MAX_MULTI_EDGES) : (j += 1) {
            const eid = deriveMultiEdgeId(idx, j);
            try std.testing.expect(eid >= MULTI_ID_BASE);
            try std.testing.expect(eid < time_floor);
            // (b) edge lane is strictly above the node lane within the window.
            try std.testing.expect(eid >= deriveMultiNodeId(idx, MAX_MULTI_NODES - 1) + 1);
        }
        // (b) the whole window of index idx is below the window of idx+1.
        const window_top = deriveMultiEdgeId(idx, MAX_MULTI_EDGES - 1);
        const next_window_bottom = deriveMultiNodeId(idx + 1, 0);
        try std.testing.expect(window_top < next_window_bottom);
    }

    // (a) A GNC2 id can never equal a plain GNC1 id (= raft_index') because the
    // smallest GNC2 id is MULTI_ID_BASE (= 1<<40), far above any realistic index.
    try std.testing.expect(deriveMultiNodeId(0, 0) == MULTI_ID_BASE);
    try std.testing.expect(MULTI_ID_BASE > max_index);
}
