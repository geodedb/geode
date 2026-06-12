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

// ---------------------------------------------------------------------------
// FTS apply-maintenance hook (2026-06-10 audit, slice 3)
// ---------------------------------------------------------------------------
//
// The EXECUTOR maintains every covering fulltext index on node create / SET /
// delete (`fts_index_ops.maintainFulltextOnWrite`), but the apply functions in
// THIS file mutate the store directly — so a follower applying committed
// entries never updated its FTS index and follower `CALL geode.fts.search`
// silently diverged from the leader.
//
// We can NOT @import the executor's fts_index_ops here: this file is compiled
// in other unit-test module roots (e.g. via the graph_store.zig closure) where
// the executor's module deps aren't mapped — the exact compile-break class hit
// with cluster.zig inline tests (commit d7a9597a). Instead the executor
// registers a callback at startup (`fts_index_ops.registerFtsApplyHook`), and
// the apply functions fire it through this seam. Null in bare codec unit tests
// (those don't exercise FTS).
//
// Op semantics MIRROR the executor's maintainFulltextOnWrite call sites:
//   * `.upsert` ↔ executor `.create` (append-only index of current props) —
//     fired AFTER the store mutation for GNC1/GNC2 create, GMRG on-match-set,
//     and GUPD set/remove. The executor deliberately uses `.create` (NOT
//     delete-then-reindex) for SET too — the fts-storage engine's tombstones
//     are permanent for a doc_id, so delete+reindex would hide the node (see
//     property_mutation.zig and docs/bugs/2026-06-07-fts-search-returns-zero-
//     results-at-runtime.md). Mirroring keeps leader and follower IDENTICAL,
//     including the documented stale-posting residual.
//   * `.delete` ↔ executor `.delete` — fired BEFORE the store node delete
//     (mirroring crud_operations.zig:4161) so labels are still resolvable.
// Edges carry no FTS content (the executor maintains FTS only on node paths),
// so edge creates/deletes never fire the hook.
//
// THREAD-SAFETY: the hook runs on the raft tick thread (apply is
// single-threaded per RaftNode). geode disables the fts engine's
// owning-thread assert (`single_writer_thread_check = false`,
// src/storage/fts_storage_adapter.zig) and the engine's internal rw_lock
// serializes this writer against the executor/connection threads.
// CANARY: REQ=REQ-DIST-CLUSTER-FTS-APPLY-SYMMETRY; FEATURE="DistributedCluster"; ASPECT=FtsApplyHook; STATUS=TESTED; TEST=tests/test_fts_apply_symmetry.zig; OWNER=distributed; UPDATED=2026-06-10

/// FTS live-maintenance op fired by the raft apply path.
pub const FtsApplyOp = enum { upsert, delete };

/// Registered hook. `store` is the store the apply mutated (the wrapper
/// no-ops unless it is the process-global store — only that store has FTS
/// adapter state). `graph` is the payload's target graph. The wrapper
/// resolves the node's labels from the store by `node_id`; for `.delete` the
/// hook fires pre-delete so labels are still resolvable. Must not fail the
/// apply: the hook returns void and logs internally.
pub const FtsApplyHook = *const fn (store: *GraphStore, graph: []const u8, node_id: u64, op: FtsApplyOp) void;

var g_fts_apply_hook: ?FtsApplyHook = null;

/// Install (or clear with null) the FTS apply-maintenance hook. Idempotent —
/// re-registering the same hook is fine. Called by
/// `fts_index_ops.registerFtsApplyHook()` at server startup / test setup.
pub fn setFtsApplyHook(hook: ?FtsApplyHook) void {
    g_fts_apply_hook = hook;
}

inline fn fireFtsApplyHook(store: *GraphStore, graph: []const u8, node_id: u64, op: FtsApplyOp) void {
    if (g_fts_apply_hook) |hook| hook(store, graph, node_id, op);
}

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

    var newly_created = true;
    store.createNodeWithId(node_id, labels.items, graph) catch |err| switch (err) {
        // Already created by a prior apply of THIS committed entry — idempotent.
        error.NodeAlreadyExists => newly_created = false,
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

    // FTS symmetry: maintain covering fulltext indexes exactly like the
    // executor's CREATE path (crud_operations.zig:1228). Fired after the
    // props land so the wrapper indexes the node's current property values.
    // Only for NEWLY created nodes: a restart re-apply (NodeAlreadyExists
    // tolerated above) must NOT re-fire — the engine is append-only with no
    // doc dedup, so a second upsert would duplicate postings and inflate the
    // restarted follower's search counts vs non-restarted nodes.
    if (newly_created) fireFtsApplyHook(store, graph, node_id, .upsert);

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

        var newly_created = true;
        store.createNodeWithId(node_id, labels.items, graph) catch |err| switch (err) {
            error.NodeAlreadyExists => newly_created = false, // idempotent re-apply
            else => return err,
        };

        const nprops = try r.readU16();
        var pi: usize = 0;
        while (pi < nprops) : (pi += 1) {
            const p = try readProp(&r);
            try store.setNodeProperty(node_id, p.key, p.value);
        }

        // FTS symmetry: per created node, after its props land. Edges below
        // carry no FTS content (executor maintains FTS only on node paths).
        // Only for NEWLY created nodes: restart re-apply (NodeAlreadyExists
        // tolerated above) must not re-fire — the engine is append-only with
        // no doc dedup, so duplicate postings would inflate search counts.
        if (newly_created) fireFtsApplyHook(store, graph, node_id, .upsert);
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

// ===========================================================================
// GDEL — deterministic DELETE / DETACH DELETE replication (leader-resolved ids)
// ===========================================================================
//
// Slice B of the cluster-replication fix. Unlike CREATE (whose ids are minted
// from the committed raft index), DELETE references PRE-EXISTING nodes/edges by
// their STABLE store ids. THE LEADER resolves the MATCH set under its execution
// lock and encodes the explicit id arrays here; followers NEVER re-run the MATCH
// (their scan order/state could differ → divergence). For DETACH the leader
// includes every incident edge id it resolves at propose time.
//
// Apply is idempotent on every node, including across restart re-apply:
// `store.deleteEdge` / `store.deleteNode` no-op when the id is already absent
// (the persisted store is the dedup oracle). Edges are deleted BEFORE nodes so a
// node-delete that precedes its incident-edge deletes in the same payload is a
// non-issue — the edges are always removed first.
//
// Caps: ≤ MAX_DELETE_IDS node ids and ≤ MAX_DELETE_IDS edge ids per entry. The
// leader fails closed (error.ClusterWriteNotReplicable) when a MATCH resolves
// more than the cap, rather than silently truncating.
//
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-DELETE; FEATURE="DistributedCluster"; ASPECT=DeleteCodec; STATUS=TESTED; TEST=tests/test_raft_apply.zig; OWNER=distributed; UPDATED=2026-06-09

/// 4-byte magic prefix identifying a GDEL delete payload.
pub const MAGIC_DEL = [4]u8{ 'G', 'D', 'E', 'L' };

/// Max node ids (or edge ids) a single GDEL entry may carry. Bounds-checked at
/// both serialize and apply time so a corrupt/oversized payload cannot OOM.
pub const MAX_DELETE_IDS: usize = 4096;

fn appendU64(list: *std.ArrayList(u8), a: std.mem.Allocator, v: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    try list.appendSlice(a, &b);
}

pub fn isDeletePayload(data: []const u8) bool {
    return data.len >= MAGIC_DEL.len and std.mem.eql(u8, data[0..MAGIC_DEL.len], &MAGIC_DEL);
}

/// Serialize an explicit DELETE id set (edge ids + node ids) resolved by the
/// leader into a self-describing GDEL payload. Edge ids are encoded first so the
/// apply path deletes them before the nodes. Rejects (fail-closed) more than
/// `MAX_DELETE_IDS` of either, so the caller never proposes an un-applyable
/// payload.
pub fn serializeDelete(
    allocator: std.mem.Allocator,
    graph: []const u8,
    edge_ids: []const u64,
    node_ids: []const u64,
) ![]u8 {
    if (edge_ids.len > MAX_DELETE_IDS or node_ids.len > MAX_DELETE_IDS)
        return CodecError.UnsupportedPropertyType;

    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);

    try list.appendSlice(allocator, &MAGIC_DEL);
    try appendStr16(&list, allocator, graph);

    try appendU16(&list, allocator, edge_ids.len);
    for (edge_ids) |eid| try appendU64(&list, allocator, eid);

    try appendU16(&list, allocator, node_ids.len);
    for (node_ids) |nid| try appendU64(&list, allocator, nid);

    return list.toOwnedSlice(allocator);
}

/// Deterministically apply a GDEL delete payload to `store`. Deletes the edges
/// first (so an incident-edge delete never lands after its node), then the
/// nodes. Idempotent: a missing id is a clean no-op (the store delete primitives
/// no-op on an absent id), so re-applying a committed entry after restart leaves
/// the graph unchanged. Returns the number of distinct edge+node ids that were
/// present (and thus actually removed) by this apply.
pub fn applyDeletePayload(allocator: std.mem.Allocator, store: *GraphStore, data: []const u8) !usize {
    _ = allocator;
    if (!isDeletePayload(data)) return CodecError.CorruptPayload;
    var r = Reader{ .data = data, .pos = MAGIC_DEL.len };

    const graph = try r.str16();
    store.createGraph(graph) catch |err| switch (err) {
        error.GraphAlreadyExists => {},
        else => return err,
    };

    var removed: usize = 0;

    // Edges FIRST — a node-delete that precedes its incident-edge deletes in the
    // payload must not orphan those edges; deleting edges up front avoids it.
    const edge_count = try r.readU16();
    if (edge_count > MAX_DELETE_IDS) return CodecError.CorruptPayload;
    var ei: usize = 0;
    while (ei < edge_count) : (ei += 1) {
        const edge_id = try r.readU64();
        if (store.getEdgePtr(edge_id) != null) {
            store.deleteEdge(edge_id);
            removed += 1;
        }
    }

    const node_count = try r.readU16();
    if (node_count > MAX_DELETE_IDS) return CodecError.CorruptPayload;
    var ni: usize = 0;
    while (ni < node_count) : (ni += 1) {
        const node_id = try r.readU64();
        if (store.getNodePtr(node_id) != null) {
            // FTS symmetry: fired BEFORE the store delete (mirroring
            // crud_operations.zig:4161) so the wrapper can still resolve the
            // node's labels to find its covering indexes.
            fireFtsApplyHook(store, graph, node_id, .delete);
            store.deleteNode(node_id);
            removed += 1;
        }
    }

    return removed;
}

// ===========================================================================
// GMRG — deterministic MERGE "matched + ON MATCH SET" replication
// ===========================================================================
//
// Slice C of the cluster-replication fix. THE CRITICAL DETERMINISM RULE: the
// MERGE match-or-create decision is made ONCE on the LEADER and shipped as a
// concrete OUTCOME; followers NEVER re-evaluate the match (their scan order
// could differ → divergence).
//
//   * NOT MATCHED  → outcome = create. The leader reuses the existing GNC1
//     node-create codec (serializeNodeCreate), so the create rides the
//     already-idempotent, raft-index-keyed create apply path. No new codec.
//   * MATCHED, no ON MATCH SET → no-op. The leader short-circuits WITHOUT
//     proposing anything (nothing mutates — semantically correct and cheap).
//   * MATCHED, with ON MATCH SET → this GMRG payload. It carries the
//     leader-resolved STABLE node id + the concrete property values; apply
//     idempotently `setNodeProperty`s by that id on every node (the matched id
//     is stable, so re-apply after restart is a clean overwrite — naturally
//     idempotent).
//
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MERGE; FEATURE="DistributedCluster"; ASPECT=MergeCodec; STATUS=TESTED; TEST=tests/test_raft_apply.zig; OWNER=distributed; UPDATED=2026-06-09

/// 4-byte magic prefix identifying a GMRG merge "matched + ON MATCH SET" payload.
pub const MAGIC_MERGE = [4]u8{ 'G', 'M', 'R', 'G' };

pub fn isMergePayload(data: []const u8) bool {
    return data.len >= MAGIC_MERGE.len and std.mem.eql(u8, data[0..MAGIC_MERGE.len], &MAGIC_MERGE);
}

/// Serialize a MERGE "matched existing node + ON MATCH SET" outcome: the
/// leader-resolved stable `node_id` plus the concrete property values to set.
/// All values must be supported scalars; anything else returns
/// `error.UnsupportedPropertyType` and the caller falls back / fails closed.
pub fn serializeMerge(
    allocator: std.mem.Allocator,
    graph: []const u8,
    node_id: u64,
    props: []const Prop,
) ![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);

    try list.appendSlice(allocator, &MAGIC_MERGE);
    try appendStr16(&list, allocator, graph);
    try appendU64(&list, allocator, node_id);
    try appendProps(&list, allocator, props);

    return list.toOwnedSlice(allocator);
}

/// Deterministically apply a GMRG payload to `store`: idempotently set the
/// resolved properties on the leader-resolved stable node id. If the node is
/// absent (it should always be present — the leader matched it), the property
/// writes are clean no-ops. Returns the node id. Naturally idempotent across
/// restart re-apply (set-by-id overwrites in place).
pub fn applyMergePayload(allocator: std.mem.Allocator, store: *GraphStore, data: []const u8) !u64 {
    _ = allocator;
    if (!isMergePayload(data)) return CodecError.CorruptPayload;
    var r = Reader{ .data = data, .pos = MAGIC_MERGE.len };

    const graph = try r.str16();
    store.createGraph(graph) catch |err| switch (err) {
        error.GraphAlreadyExists => {},
        else => return err,
    };

    const node_id = try r.readU64();

    const nprops = try r.readU16();
    var pi: usize = 0;
    while (pi < nprops) : (pi += 1) {
        const p = try readProp(&r);
        // Idempotent: setNodeProperty no-ops if the node is absent and overwrites
        // in place otherwise.
        try store.setNodeProperty(node_id, p.key, p.value);
    }

    // FTS symmetry: ON MATCH SET mutates node content — maintain covering
    // indexes like the executor's SET chokepoint (property_mutation.zig).
    // The wrapper no-ops if the node is absent.
    // Intentionally unconditional on re-apply: set-overwrite re-firing matches
    // the executor's repeated-SET semantics — symmetric with the leader.
    fireFtsApplyHook(store, graph, node_id, .upsert);

    return node_id;
}

// ===========================================================================
// GUPD — deterministic MATCH…SET / MATCH…REMOVE replication (leader-resolved)
// ===========================================================================
//
// Slice D of the cluster-replication fix — closes the SILENT-DIVERGENCE gap:
// MATCH…SET / MATCH…REMOVE without CREATE/MERGE/DELETE was NOT cluster-gated at
// all, so a leader SET mutated ONLY the leader's local store (followers kept the
// old value). Like DELETE/MERGE, SET/REMOVE reference PRE-EXISTING nodes by their
// STABLE store ids; THE LEADER resolves the MATCH set AND evaluates the SET
// expressions to CONCRETE scalar values under its execution path, then ships the
// (node_id, concrete-set-props, removed-prop-keys, added-labels, removed-labels)
// tuples here. Followers NEVER re-MATCH and NEVER re-evaluate an expression like
// `n.v + 1` (which would diverge on a different starting value).
//
// One GUPD entry carries up to MAX_UPDATE_NODES per-node update records (a
// `MATCH (n:L) SET n.v = 2` binds many nodes). The leader fails closed
// (error.ClusterWriteNotReplicable) above the cap rather than truncating.
//
// Apply is idempotent on every node, including across restart re-apply: a set is
// an overwrite-by-id, a remove of an absent key is a clean no-op, an add of an
// existing label is a no-op, and a remove of an absent label is a no-op (the
// store primitives tolerate all four). The persisted graph is the dedup oracle.
//
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MATCH-SET; FEATURE="DistributedCluster"; ASPECT=UpdateCodec; STATUS=TESTED; TEST=tests/test_raft_apply.zig; OWNER=distributed; UPDATED=2026-06-09

/// 4-byte magic prefix identifying a GUPD MATCH…SET/REMOVE payload.
pub const MAGIC_UPDATE = [4]u8{ 'G', 'U', 'P', 'D' };

/// Max per-node update records a single GUPD entry may carry. Bounds-checked at
/// both serialize and apply time so a corrupt/oversized payload cannot OOM.
pub const MAX_UPDATE_NODES: usize = 4096;

/// A leader-resolved per-node update: the stable `node_id` plus the concrete
/// property sets, the property keys to remove, and the labels to add / remove.
/// All `set_props` values are concrete scalars evaluated on the leader.
pub const NodeUpdate = struct {
    node_id: u64,
    set_props: []const Prop = &.{},
    remove_props: []const []const u8 = &.{},
    add_labels: []const []const u8 = &.{},
    remove_labels: []const []const u8 = &.{},
};

pub fn isUpdatePayload(data: []const u8) bool {
    return data.len >= MAGIC_UPDATE.len and std.mem.eql(u8, data[0..MAGIC_UPDATE.len], &MAGIC_UPDATE);
}

fn appendStrList(list: *std.ArrayList(u8), a: std.mem.Allocator, items: []const []const u8) !void {
    try appendU16(list, a, items.len);
    for (items) |s| try appendStr16(list, a, s);
}

/// Serialize a leader-resolved MATCH…SET/REMOVE outcome (one or more per-node
/// updates) into a self-describing GUPD payload. All `set_props` values must be
/// supported scalars (the caller maps them via clusterPropValue, fail-closed on
/// non-scalars). Rejects (fail-closed) more than `MAX_UPDATE_NODES` records.
pub fn serializeUpdate(
    allocator: std.mem.Allocator,
    graph: []const u8,
    updates: []const NodeUpdate,
) ![]u8 {
    if (updates.len > MAX_UPDATE_NODES) return CodecError.UnsupportedPropertyType;

    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);

    try list.appendSlice(allocator, &MAGIC_UPDATE);
    try appendStr16(&list, allocator, graph);

    try appendU16(&list, allocator, updates.len);
    for (updates) |u| {
        try appendU64(&list, allocator, u.node_id);
        try appendProps(&list, allocator, u.set_props);
        try appendStrList(&list, allocator, u.remove_props);
        try appendStrList(&list, allocator, u.add_labels);
        try appendStrList(&list, allocator, u.remove_labels);
    }

    return list.toOwnedSlice(allocator);
}

/// Deterministically apply a GUPD payload to `store`. For each per-node record,
/// in payload order: set the concrete properties, remove the named property keys,
/// add the labels, then remove the labels — all keyed by the leader-resolved
/// stable node id. Idempotent on every node and across restart re-apply (set is
/// an overwrite; remove-absent / add-existing / remove-absent label are all clean
/// no-ops; a label add/remove on an absent node is swallowed). Returns the number
/// of node-update records applied.
pub fn applyUpdatePayload(allocator: std.mem.Allocator, store: *GraphStore, data: []const u8) !usize {
    _ = allocator;
    if (!isUpdatePayload(data)) return CodecError.CorruptPayload;
    var r = Reader{ .data = data, .pos = MAGIC_UPDATE.len };

    const graph = try r.str16();
    store.createGraph(graph) catch |err| switch (err) {
        error.GraphAlreadyExists => {},
        else => return err,
    };

    const update_count = try r.readU16();
    if (update_count > MAX_UPDATE_NODES) return CodecError.CorruptPayload;

    var ui: usize = 0;
    while (ui < update_count) : (ui += 1) {
        const node_id = try r.readU64();

        // set_props
        const nset = try r.readU16();
        var si: usize = 0;
        while (si < nset) : (si += 1) {
            const p = try readProp(&r);
            // Idempotent: setNodeProperty no-ops if the node is absent and
            // overwrites in place otherwise.
            try store.setNodeProperty(node_id, p.key, p.value);
        }

        // remove_props
        const nrem = try r.readU16();
        var ri: usize = 0;
        while (ri < nrem) : (ri += 1) {
            const key = try r.str16();
            // removeNodeProperty no-ops on an absent node OR an absent key.
            store.removeNodeProperty(node_id, key);
        }

        // add_labels
        const nadd = try r.readU16();
        var ai: usize = 0;
        while (ai < nadd) : (ai += 1) {
            const label = try r.str16();
            store.addNodeLabel(node_id, label) catch |err| switch (err) {
                error.NodeNotFound => {}, // idempotent: absent node is a no-op
                else => return err,
            };
        }

        // remove_labels
        const ndel = try r.readU16();
        var di: usize = 0;
        while (di < ndel) : (di += 1) {
            const label = try r.str16();
            store.removeNodeLabel(node_id, label) catch |err| switch (err) {
                error.NodeNotFound => {}, // idempotent: absent node is a no-op
                else => return err,
            };
        }

        // FTS symmetry: the per-node record mutated content — maintain
        // covering indexes like the executor's SET chokepoint
        // (property_mutation.zig). Fired after label add/remove so the
        // wrapper resolves the node's FINAL label set for this record.
        // Intentionally unconditional on re-apply: set-overwrite re-firing
        // matches the executor's repeated-SET semantics — symmetric.
        fireFtsApplyHook(store, graph, node_id, .upsert);
    }

    return update_count;
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

// ---------------------------------------------------------------------------
// GDEL delete tests
// ---------------------------------------------------------------------------

test "GDEL delete round-trips: detach delete removes node + incident edge" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    try store.createNodeWithId(10, &.{"D"}, "default");
    try store.createNodeWithId(11, &.{"D"}, "default");
    try store.createEdgeWithId(20, 10, 11, "LINKS", "default");

    const edge_ids = [_]u64{20};
    const node_ids = [_]u64{10};
    const payload = try serializeDelete(a, "default", &edge_ids, &node_ids);
    defer a.free(payload);
    try std.testing.expect(isDeletePayload(payload));

    const removed = try applyDeletePayload(a, &store, payload);
    try std.testing.expectEqual(@as(usize, 2), removed); // 1 edge + 1 node
    try std.testing.expect(store.getEdgePtr(20) == null);
    try std.testing.expect(store.getNodePtr(10) == null);
    try std.testing.expect(store.getNodePtr(11) != null); // untouched
}

test "GDEL apply is idempotent across restart re-apply" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    try store.createNodeWithId(10, &.{"D"}, "default");
    const node_ids = [_]u64{10};
    const payload = try serializeDelete(a, "default", &.{}, &node_ids);
    defer a.free(payload);

    _ = try applyDeletePayload(a, &store, payload);
    _ = try applyDeletePayload(a, &store, payload); // restart replay — clean no-op
    try std.testing.expectEqual(@as(usize, 0), store.nodes.count());
}

test "GDEL over-cap id set is rejected at serialize time" {
    const a = std.testing.allocator;
    const big = try a.alloc(u64, MAX_DELETE_IDS + 1);
    defer a.free(big);
    for (big, 0..) |*v, i| v.* = @intCast(i);
    try std.testing.expectError(CodecError.UnsupportedPropertyType, serializeDelete(a, "default", big, &.{}));
}

test "GDEL truncated payload is rejected, not crashed" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();
    const edge_ids = [_]u64{20};
    const node_ids = [_]u64{10};
    const full = try serializeDelete(a, "default", &edge_ids, &node_ids);
    defer a.free(full);
    try std.testing.expectError(CodecError.CorruptPayload, applyDeletePayload(a, &store, full[0 .. full.len - 3]));
}

// ---------------------------------------------------------------------------
// GMRG merge (matched + ON MATCH SET) tests
// ---------------------------------------------------------------------------

test "GMRG merge round-trips: matched node + ON MATCH SET overwrites by id" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    // Leader-matched node at a stable id with an initial value.
    try store.createNodeWithId(77, &.{"M"}, "default");
    try store.setNodeProperty(77, "v", .{ .Int = 1 });

    const props = [_]Prop{.{ .key = "v", .value = .{ .Int = 2 } }};
    const payload = try serializeMerge(a, "default", 77, &props);
    defer a.free(payload);
    try std.testing.expect(isMergePayload(payload));

    const node_id = try applyMergePayload(a, &store, payload);
    try std.testing.expectEqual(@as(u64, 77), node_id);
    try std.testing.expectEqual(@as(i64, 2), store.getNodeProperty(77, "v").?.Int);
}

test "GMRG apply is idempotent across restart re-apply (set-by-id overwrite)" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    try store.createNodeWithId(5, &.{"M"}, "default");
    const props = [_]Prop{.{ .key = "name", .value = .{ .String = "bob" } }};
    const payload = try serializeMerge(a, "default", 5, &props);
    defer a.free(payload);

    _ = try applyMergePayload(a, &store, payload);
    _ = try applyMergePayload(a, &store, payload); // restart replay — clean overwrite
    try std.testing.expectEqual(@as(usize, 1), store.nodes.count());
    try std.testing.expectEqualStrings("bob", store.getNodeProperty(5, "name").?.String);
}

test "GMRG truncated payload is rejected, not crashed" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();
    const props = [_]Prop{.{ .key = "v", .value = .{ .Int = 1 } }};
    const full = try serializeMerge(a, "default", 9, &props);
    defer a.free(full);
    try std.testing.expectError(CodecError.CorruptPayload, applyMergePayload(a, &store, full[0 .. full.len - 3]));
}

// ---------------------------------------------------------------------------
// GUPD MATCH…SET / MATCH…REMOVE tests
// ---------------------------------------------------------------------------

test "GUPD set round-trips: SET n.v = 2 overwrites by stable id" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    // Leader-matched node at a stable id with v=1 (the SetRepl regression shape).
    try store.createNodeWithId(33, &.{"SetRepl"}, "default");
    try store.setNodeProperty(33, "v", .{ .Int = 1 });

    const set_props = [_]Prop{.{ .key = "v", .value = .{ .Int = 2 } }};
    const updates = [_]NodeUpdate{.{ .node_id = 33, .set_props = &set_props }};
    const payload = try serializeUpdate(a, "default", &updates);
    defer a.free(payload);
    try std.testing.expect(isUpdatePayload(payload));

    const applied = try applyUpdatePayload(a, &store, payload);
    try std.testing.expectEqual(@as(usize, 1), applied);
    try std.testing.expectEqual(@as(i64, 2), store.getNodeProperty(33, "v").?.Int);
}

test "GUPD apply is idempotent across restart re-apply (set-by-id overwrite)" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    try store.createNodeWithId(7, &.{"S"}, "default");
    const set_props = [_]Prop{.{ .key = "name", .value = .{ .String = "carol" } }};
    const updates = [_]NodeUpdate{.{ .node_id = 7, .set_props = &set_props }};
    const payload = try serializeUpdate(a, "default", &updates);
    defer a.free(payload);

    _ = try applyUpdatePayload(a, &store, payload);
    _ = try applyUpdatePayload(a, &store, payload); // restart replay — clean overwrite
    try std.testing.expectEqual(@as(usize, 1), store.nodes.count());
    try std.testing.expectEqualStrings("carol", store.getNodeProperty(7, "name").?.String);
}

test "GUPD remove of an absent prop is a clean no-op" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    try store.createNodeWithId(9, &.{"S"}, "default");
    try store.setNodeProperty(9, "keep", .{ .Int = 5 });

    const removes = [_][]const u8{ "ghost", "alsoMissing" };
    const updates = [_]NodeUpdate{.{ .node_id = 9, .remove_props = &removes }};
    const payload = try serializeUpdate(a, "default", &updates);
    defer a.free(payload);

    _ = try applyUpdatePayload(a, &store, payload);
    _ = try applyUpdatePayload(a, &store, payload); // re-apply — still a no-op
    // The untouched property survives; the absent removes did nothing.
    try std.testing.expectEqual(@as(i64, 5), store.getNodeProperty(9, "keep").?.Int);
    try std.testing.expect(store.getNodeProperty(9, "ghost") == null);
}

test "GUPD remove of a present prop deletes it" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    try store.createNodeWithId(11, &.{"S"}, "default");
    try store.setNodeProperty(11, "drop", .{ .Int = 1 });
    try store.setNodeProperty(11, "keep", .{ .Int = 2 });

    const removes = [_][]const u8{"drop"};
    const updates = [_]NodeUpdate{.{ .node_id = 11, .remove_props = &removes }};
    const payload = try serializeUpdate(a, "default", &updates);
    defer a.free(payload);

    _ = try applyUpdatePayload(a, &store, payload);
    try std.testing.expect(store.getNodeProperty(11, "drop") == null);
    try std.testing.expectEqual(@as(i64, 2), store.getNodeProperty(11, "keep").?.Int);
}

test "GUPD label add/remove round-trips by stable id" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    try store.createNodeWithId(13, &.{"Base"}, "default");

    const adds = [_][]const u8{"Added"};
    const removes = [_][]const u8{"Base"};
    const updates = [_]NodeUpdate{.{ .node_id = 13, .add_labels = &adds, .remove_labels = &removes }};
    const payload = try serializeUpdate(a, "default", &updates);
    defer a.free(payload);

    _ = try applyUpdatePayload(a, &store, payload);
    _ = try applyUpdatePayload(a, &store, payload); // re-apply: add-existing / remove-absent are no-ops

    const node = store.getNodePtr(13).?;
    var has_added = false;
    var has_base = false;
    for (node.labels) |l| {
        if (std.mem.eql(u8, l, "Added")) has_added = true;
        if (std.mem.eql(u8, l, "Base")) has_base = true;
    }
    try std.testing.expect(has_added);
    try std.testing.expect(!has_base);
}

test "GUPD multi-node update payload sets every bound node" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    try store.createNodeWithId(100, &.{"M"}, "default");
    try store.createNodeWithId(101, &.{"M"}, "default");
    try store.createNodeWithId(102, &.{"M"}, "default");

    const sp = [_]Prop{.{ .key = "v", .value = .{ .Int = 2 } }};
    const updates = [_]NodeUpdate{
        .{ .node_id = 100, .set_props = &sp },
        .{ .node_id = 101, .set_props = &sp },
        .{ .node_id = 102, .set_props = &sp },
    };
    const payload = try serializeUpdate(a, "default", &updates);
    defer a.free(payload);

    const applied = try applyUpdatePayload(a, &store, payload);
    try std.testing.expectEqual(@as(usize, 3), applied);
    try std.testing.expectEqual(@as(i64, 2), store.getNodeProperty(100, "v").?.Int);
    try std.testing.expectEqual(@as(i64, 2), store.getNodeProperty(101, "v").?.Int);
    try std.testing.expectEqual(@as(i64, 2), store.getNodeProperty(102, "v").?.Int);
}

test "GUPD cross-store convergence: two stores apply same payload -> identical state" {
    const a = std.testing.allocator;
    var s1 = try GraphStore.init(a);
    defer s1.deinit();
    var s2 = try GraphStore.init(a);
    defer s2.deinit();

    try s1.createNodeWithId(50, &.{"C"}, "default");
    try s2.createNodeWithId(50, &.{"C"}, "default");

    const sp = [_]Prop{.{ .key = "v", .value = .{ .Int = 9 } }};
    const updates = [_]NodeUpdate{.{ .node_id = 50, .set_props = &sp }};
    const payload = try serializeUpdate(a, "default", &updates);
    defer a.free(payload);

    _ = try applyUpdatePayload(a, &s1, payload);
    _ = try applyUpdatePayload(a, &s2, payload);
    try std.testing.expectEqual(@as(i64, 9), s1.getNodeProperty(50, "v").?.Int);
    try std.testing.expectEqual(@as(i64, 9), s2.getNodeProperty(50, "v").?.Int);
}

test "GUPD over-cap update set is rejected at serialize time" {
    const a = std.testing.allocator;
    const big = try a.alloc(NodeUpdate, MAX_UPDATE_NODES + 1);
    defer a.free(big);
    for (big, 0..) |*u, i| u.* = .{ .node_id = @intCast(i) };
    try std.testing.expectError(CodecError.UnsupportedPropertyType, serializeUpdate(a, "default", big));
}

test "GUPD truncated payload is rejected, not crashed" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();
    const sp = [_]Prop{.{ .key = "v", .value = .{ .Int = 1 } }};
    const updates = [_]NodeUpdate{.{ .node_id = 1, .set_props = &sp }};
    const full = try serializeUpdate(a, "default", &updates);
    defer a.free(full);
    try std.testing.expectError(CodecError.CorruptPayload, applyUpdatePayload(a, &store, full[0 .. full.len - 3]));
}
