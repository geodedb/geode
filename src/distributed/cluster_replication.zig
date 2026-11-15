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
const logging = @import("logging");
const log = logging.scoped("cluster_replication");
const Attr = logging.Attr;

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
//   * `.create` indexes a newly created GNC1/GNC2 node once, even when its
//     notification races an FTS rebuild's backfill.
//   * `.upsert` appends current properties after GMRG on-match-set or GUPD
//     set/remove, matching the executor's SET hook. It must not tombstone the
//     id: the pinned engine's tombstones are permanent, so delete+reindex
//     would hide the node. Text the entry took away (a replaced or removed
//     string) queues the covering indexes for a rebuild at the end of the
//     entry, as the executor does at a statement's end (SONNY-6433,
//     `FtsApplyTextHooks`).
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
pub const FtsApplyOp = enum { create, upsert, delete };

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

// CANARY: REQ=REQ-SONNY-6433-FOLLOWER-FTS-REBUILD; FEATURE="DistributedCluster"; ASPECT=ApplyQueuesRemovedText; STATUS=TESTED; TEST=tests/test_sonny6433_follower_fts_rebuild.zig; OWNER=distributed; UPDATED=2026-11-12
/// SONNY-6433: text a node lost in an applied entry. The fts engine cannot
/// take words out of a document, so the executor queues each covering
/// full-text index for a rebuild when a SET replaces a non-empty string or a
/// REMOVE drops one (`fts_index_ops.queueRebuildForRemovedText`) and rebuilds
/// them at the statement's end. The apply functions below report the same
/// losses through `FtsApplyTextHooks.removed` (after the write; the
/// property's key) and end each applied entry with `FtsApplyTextHooks.flush`,
/// so a follower drops the old words as the leader does (it appended the
/// new text and kept the old). Both run on the apply thread, a follower's
/// only writer (every write on a follower is refused).
pub const FtsApplyTextHooks = struct {
    removed: *const fn (store: *GraphStore, graph: []const u8, node_id: u64, key: []const u8) void,
    flush: *const fn (store: *GraphStore) void,
};

var g_fts_apply_text_hooks: ?FtsApplyTextHooks = null;

/// Install (or clear with null) the hooks; `fts_index_ops.registerFtsApplyHook`.
pub fn setFtsApplyTextHooks(hooks: ?FtsApplyTextHooks) void {
    g_fts_apply_text_hooks = hooks;
}

inline fn fireFtsRemovedText(store: *GraphStore, graph: []const u8, node_id: u64, key: []const u8) void {
    if (g_fts_apply_text_hooks) |h| h.removed(store, graph, node_id, key);
}

inline fn fireFtsFlush(store: *GraphStore) void {
    if (g_fts_apply_text_hooks) |h| h.flush(store);
}

/// Does setting (or, `new` null, removing) `key` take a non-empty string
/// away from the node? As `property_mutation.replacesText`.
fn losesText(store: *GraphStore, node_id: u64, key: []const u8, new: ?PropertyValue) bool {
    if (g_fts_apply_text_hooks == null) return false;
    const old = store.getNodeProperty(node_id, key) orelse return false;
    if (old != .String or old.String.len == 0) return false;
    const n = new orelse return true;
    return n != .String or !std.mem.eql(u8, n.String, old.String);
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
    store.ensureGraphForReplicatedWrite(graph) catch |err| switch (err) {
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
    if (newly_created) fireFtsApplyHook(store, graph, node_id, .create);

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
    return applyMultiCreatePayloadAt(allocator, store, data, MULTI_ID_BASE + raft_index * MULTI_LANE_STRIDE);
}

/// `applyMultiCreatePayload` with the entry's lane window given: node `k` is
/// `lane_base + k`, edge `j` is `lane_base + MAX_MULTI_NODES + j`. A GNC2
/// entry of its own uses the window of its raft index; one inside a GBAT batch
/// uses the window of its position in the batch (`batchLaneBase`).
fn applyMultiCreatePayloadAt(
    allocator: std.mem.Allocator,
    store: *GraphStore,
    data: []const u8,
    lane_base: u64,
) !usize {
    if (!isMultiCreatePayload(data)) return CodecError.CorruptPayload;
    var r = Reader{ .data = data, .pos = MAGIC2.len };

    const graph = try r.str16();
    store.ensureGraphForReplicatedWrite(graph) catch |err| switch (err) {
        error.GraphAlreadyExists => {},
        else => return err,
    };

    const node_count = try r.readU16();
    if (node_count > MAX_MULTI_NODES) return CodecError.CorruptPayload;

    var labels = std.ArrayList([]const u8).empty;
    defer labels.deinit(allocator);

    var k: usize = 0;
    while (k < node_count) : (k += 1) {
        const node_id = lane_base + @as(u64, @intCast(k));

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
        if (newly_created) fireFtsApplyHook(store, graph, node_id, .create);
    }

    const edge_count = try r.readU16();
    if (edge_count > MAX_MULTI_EDGES) return CodecError.CorruptPayload;

    var j: usize = 0;
    while (j < edge_count) : (j += 1) {
        const from_ep = try readEndpoint(&r);
        const to_ep = try readEndpoint(&r);
        const edge_type = try r.str16();
        const nprops = try r.readU16();

        const from_id = resolveEndpointAt(from_ep, lane_base, node_count) orelse return CodecError.CorruptPayload;
        const to_id = resolveEndpointAt(to_ep, lane_base, node_count) orelse return CodecError.CorruptPayload;
        const edge_id = lane_base + MAX_MULTI_NODES + @as(u64, @intCast(j));

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

fn resolveEndpointAt(ep: Endpoint, lane_base: u64, node_count: u16) ?u64 {
    return switch (ep) {
        .position => |p| if (p < node_count) lane_base + @as(u64, p) else null,
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
    store.ensureGraphForReplicatedWrite(graph) catch |err| switch (err) {
        error.GraphAlreadyExists => {},
        else => return err,
    };

    var removed: usize = 0;
    // CANARY: REQ=REQ-SONNY-6302-WRITE-ERRORS; FEATURE="DistributedCluster"; ASPECT=ApplyDeleteFailure; STATUS=TESTED; TEST=tests/test_sonny6302_edge_write_and_delete_errors.zig; OWNER=distributed; UPDATED=2026-11-11
    // SONNY-6302: a delete that fails is logged, the rest of the payload is
    // still applied (the deletes are independent, and stopping would leave
    // more of this node behind the leader), and the first error is returned
    // so the raft apply loop logs the entry as not applied and counts it
    // (`stats.apply_errors`). Apply stays idempotent, so a re-apply finishes
    // it. (The void deletes only logged a failure, and the entry counted the
    // id as removed and reported success.)
    var first_err: ?anyerror = null;

    // Edges FIRST — a node-delete that precedes its incident-edge deletes in the
    // payload must not orphan those edges; deleting edges up front avoids it.
    const edge_count = try r.readU16();
    if (edge_count > MAX_DELETE_IDS) return CodecError.CorruptPayload;
    var ei: usize = 0;
    while (ei < edge_count) : (ei += 1) {
        const edge_id = try r.readU64();
        if (store.getEdgePtr(edge_id) != null) {
            if (store.deleteEdgeChecked(edge_id)) |_| {
                removed += 1;
            } else |err| {
                log.err("replicated delete: edge delete failed; the edge remains", &.{
                    Attr.uint("edge_id", edge_id),
                    Attr.string("error", @errorName(err)),
                });
                if (first_err == null) first_err = err;
            }
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
            if (store.deleteNodeChecked(node_id)) |_| {
                removed += 1;
            } else |err| {
                log.err("replicated delete: node delete failed; the node remains", &.{
                    Attr.uint("node_id", node_id),
                    Attr.string("error", @errorName(err)),
                });
                if (first_err == null) first_err = err;
            }
        }
    }

    if (first_err) |err| return err;
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
    store.ensureGraphForReplicatedWrite(graph) catch |err| switch (err) {
        error.GraphAlreadyExists => {},
        else => return err,
    };

    const node_id = try r.readU64();

    const nprops = try r.readU16();
    var pi: usize = 0;
    while (pi < nprops) : (pi += 1) {
        const p = try readProp(&r);
        const lost = losesText(store, node_id, p.key, p.value); // SONNY-6433
        // Idempotent: setNodeProperty no-ops if the node is absent and overwrites
        // in place otherwise.
        try store.setNodeProperty(node_id, p.key, p.value);
        if (lost) fireFtsRemovedText(store, graph, node_id, p.key);
    }

    // FTS symmetry: ON MATCH SET mutates node content — maintain covering
    // indexes like the executor's SET chokepoint (property_mutation.zig).
    // The wrapper no-ops if the node is absent.
    // Intentionally unconditional on re-apply: set-overwrite re-firing matches
    // the executor's repeated-SET semantics — symmetric with the leader.
    fireFtsApplyHook(store, graph, node_id, .upsert);
    fireFtsFlush(store); // SONNY-6433

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
    store.ensureGraphForReplicatedWrite(graph) catch |err| switch (err) {
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
            const lost = losesText(store, node_id, p.key, p.value); // SONNY-6433
            // Idempotent: setNodeProperty no-ops if the node is absent and
            // overwrites in place otherwise.
            try store.setNodeProperty(node_id, p.key, p.value);
            if (lost) fireFtsRemovedText(store, graph, node_id, p.key);
        }

        // remove_props
        const nrem = try r.readU16();
        var ri: usize = 0;
        while (ri < nrem) : (ri += 1) {
            const key = try r.str16();
            const lost = losesText(store, node_id, key, null); // SONNY-6433
            // removeNodeProperty no-ops on an absent node OR an absent key.
            store.removeNodeProperty(node_id, key);
            if (lost) fireFtsRemovedText(store, graph, node_id, key);
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
    // SONNY-6433: rebuild the indexes this entry queued, as the executor
    // does at a statement's end.
    fireFtsFlush(store);

    return update_count;
}

// ===========================================================================
// RC-3 — client idempotency key dedup ("committed write -> client Timeout ->
// retry double-insert", 2026-06-12)
// ===========================================================================
//
// THE BUG: a CREATE that committed but whose client saw a Timeout (RC-1/RC-2)
// is RE-PROPOSED by the retrying client, lands at a NEW raft index, and mints
// NEW ids (GNC1 id == raft_index, GNC2 ids derived from raft_index) — a
// DUPLICATE row. The persisted store deduped only by raft index (restart
// replay), never by the logical client request.
//
// THE FIX: an OPTIONAL client idempotency key rides the replicated create
// payload. At apply time a deterministic key -> original-raft-index dedup table
// makes a same-key-DIFFERENT-index apply a NO-OP (the retry case). Same-key-
// SAME-index re-apply (restart replay) stays the normal index-idempotent path.
// A keyless (legacy) payload applies EXACTLY as before — backward compatible.
//
// CODEC EVOLUTION (mixed-version-safe): rather than mutate the GNC1/GNC2 body,
// a keyed create is a self-describing WRAPPER with its own 4-byte magic
// (GN1K / GN2K) carrying an optional-key header followed by the UNCHANGED
// legacy GNC1/GNC2 payload. A node running the fixed code recognizes both the
// wrapper (keyed) and the bare legacy magic (keyless, already committed in the
// log before the roll). A node running OLD code never sees a GN1K/GN2K wrapper
// because the leader only emits one when a client supplies a key, AND the apply
// dispatch's unknown-magic arm already log-and-skips (raft_apply.zig) rather
// than minting junk — so a stray wrapper on an un-upgraded node is inert, not
// corrupting. The wrapper distinguishes "no key" (header byte 0) from "empty
// key" (header byte 1 + zero-length string), satisfying idempotencyKeyOf's
// null-vs-present contract.
//
// DETERMINISM: the dedup table is rebuilt naturally by replay — geode re-applies
// the full committed log on restart (no compaction), so every replica processes
// the SAME keyed entries in the SAME order and reaches the SAME table + eviction
// state. The table is bounded (LRU by insertion order, generous cap) so it
// cannot grow without bound; identical insertion order across replicas ⇒
// identical eviction ⇒ deterministic.
//
// CANARY: REQ=REQ-DIST-CLUSTER-IDEMPOTENT-RETRY; FEATURE="DistributedCluster"; ASPECT=IdempotencyKeyDedup; STATUS=TESTED; TEST=tests/test_cluster_write_idempotency.zig; OWNER=distributed; UPDATED=2026-06-12

/// 4-byte magic prefix identifying a GNC1 (single-node create) payload wrapped
/// with an optional idempotency key.
pub const MAGIC_KEYED1 = [4]u8{ 'G', 'N', '1', 'K' };

/// 4-byte magic prefix identifying a GNC2 (multi-create) payload wrapped with an
/// optional idempotency key.
pub const MAGIC_KEYED2 = [4]u8{ 'G', 'N', '2', 'K' };

/// Generous bound on the key -> original-index table. The same committed log is
/// replayed on every replica in the same order, so insertion-order LRU eviction
/// is deterministic across replicas. 64k entries is far above any realistic
/// in-flight-retry window while bounding memory (~key bytes + 8 bytes/entry).
pub const IDEMPOTENCY_DEDUP_CAP: usize = 64 * 1024;

/// Bounded, deterministic key -> original-raft-index dedup table. Rebuilt
/// naturally by replay (the full committed log re-applies on restart). Eviction
/// is LRU by INSERTION order (a committed key is recorded once, at its first
/// apply, and never re-touched), so every replica processing the same log
/// reaches the same table and the same eviction state.
///
/// The fixer owns the exact shape; the apply functions consult & populate it.
pub const IdempotencyDedup = struct {
    allocator: std.mem.Allocator,
    /// key (owned copy) -> original raft index where the key was first applied.
    map: std.StringHashMap(u64),
    /// Insertion-order ring of the owned key slices, for O(1) LRU eviction of
    /// the OLDEST inserted key once the cap is reached. Indices into `order`
    /// are never reused while an entry is live; eviction pops from the front.
    order: std.ArrayList([]const u8),
    /// Front cursor into `order` (the next key to evict). Entries before it have
    /// already been evicted (their slots are stale/null-equivalent).
    head: usize = 0,

    pub fn init(allocator: std.mem.Allocator) IdempotencyDedup {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(u64).init(allocator),
            .order = std.ArrayList([]const u8).empty,
        };
    }

    pub fn deinit(self: *IdempotencyDedup) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.map.deinit();
        self.order.deinit(self.allocator);
    }

    /// The original raft index a key was first applied at, or null if unseen.
    pub fn lookup(self: *const IdempotencyDedup, key: []const u8) ?u64 {
        return self.map.get(key);
    }

    /// Record `key` -> `raft_index` if absent. A duplicate record (same key seen
    /// again, e.g. restart replay of the SAME committed entry) is a no-op — the
    /// FIRST recorded index is authoritative and stable across replays. Evicts
    /// the oldest-inserted key once the cap is exceeded (deterministic LRU).
    pub fn record(self: *IdempotencyDedup, key: []const u8, raft_index: u64) !void {
        if (self.map.contains(key)) return; // first index wins; replay is a no-op
        const owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned);
        try self.map.put(owned, raft_index);
        try self.order.append(self.allocator, owned);
        // Evict oldest live entries until back within cap. Deterministic: same
        // log order on every replica ⇒ same eviction sequence.
        while (self.map.count() > IDEMPOTENCY_DEDUP_CAP and self.head < self.order.items.len) {
            const victim = self.order.items[self.head];
            self.head += 1;
            if (self.map.fetchRemove(victim)) |kv| self.allocator.free(kv.key);
        }
        // Compact the order ring once the consumed front dominates it, so its
        // backing array stays O(live entries) instead of growing with total
        // history. Deterministic: the trigger depends only on counts, identical
        // on every replica processing the same log. The freed front slots held
        // dangling pointers (already evicted from the map) — never dereferenced.
        if (self.head > 0 and self.head * 2 >= self.order.items.len) {
            const live = self.order.items[self.head..];
            std.mem.copyForwards([]const u8, self.order.items[0..live.len], live);
            self.order.shrinkRetainingCapacity(live.len);
            self.head = 0;
        }
    }

    // CANARY: REQ=REQ-SONNY-6633-DEDUP-IN-SNAPSHOT; FEATURE="DistributedCluster"; ASPECT=DedupSerialized; STATUS=TESTED; TEST=tests/test_sonny6633_snapshot_wire.zig; OWNER=distributed; UPDATED=2026-11-15
    /// SONNY-6633 (6): append the live keys, oldest first, to `out`:
    /// u32 count, then per key u16 length, the key, u64 raft index. A Raft
    /// snapshot carries it: the table is otherwise rebuilt by replaying the
    /// committed log, and a snapshot replaces the entries it covers.
    pub fn serialize(self: *const IdempotencyDedup, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        try appendU32(out, allocator, self.map.count());
        for (self.order.items[self.head..]) |key| {
            const index = self.map.get(key) orelse continue;
            try appendStr16(out, allocator, key);
            try appendU64(out, allocator, index);
        }
    }

    /// SONNY-6633 (6): replace the table with one `serialize` wrote, in the
    /// same order (so later evictions match the replicas'). `data` must be
    /// exactly that encoding.
    pub fn replaceFrom(self: *IdempotencyDedup, data: []const u8) !void {
        var fresh = IdempotencyDedup.init(self.allocator);
        errdefer fresh.deinit();
        var r = Reader{ .data = data, .pos = 0 };
        const count = try r.readU32();
        for (0..count) |_| {
            const key = try r.str16();
            try fresh.record(key, try r.readU64());
        }
        if (r.pos != data.len) return CodecError.CorruptPayload;
        self.deinit();
        self.* = fresh;
    }
};

/// Read the idempotency key from a keyed (GN1K / GN2K) payload, or null for a
/// keyless legacy (GNC1 / GNC2 / any non-wrapper) payload. Distinguishes "no
/// key" (null) from "empty key" (a present, zero-length key). Borrows into
/// `data`; the slice is valid for the lifetime of `data`.
pub fn idempotencyKeyOf(data: []const u8) ?[]const u8 {
    if (!isKeyedPayload(data)) return null;
    var r = Reader{ .data = data, .pos = MAGIC_KEYED1.len };
    const present = r.byte() catch return null;
    if (present == 0) return null;
    return r.str16() catch null;
}

/// True iff `data` is a GN1K or GN2K keyed-create wrapper.
pub fn isKeyedPayload(data: []const u8) bool {
    return (data.len >= MAGIC_KEYED1.len and std.mem.eql(u8, data[0..MAGIC_KEYED1.len], &MAGIC_KEYED1)) or
        (data.len >= MAGIC_KEYED2.len and std.mem.eql(u8, data[0..MAGIC_KEYED2.len], &MAGIC_KEYED2));
}

/// Encode the optional-key header: byte 0 = no key; byte 1 + str16 = present key
/// (possibly empty). Returns the cursor just past the header.
fn appendKeyHeader(list: *std.ArrayList(u8), a: std.mem.Allocator, key: ?[]const u8) !void {
    if (key) |k| {
        try list.append(a, 1);
        try appendStr16(list, a, k);
    } else {
        try list.append(a, 0);
    }
}

/// Split a keyed wrapper into (key, inner legacy body). `data` must be a keyed
/// payload (caller checks isKeyedPayload). The inner body is the UNCHANGED
/// legacy GNC1/GNC2 payload (with its own magic), borrowed from `data`.
const KeyedSplit = struct { key: ?[]const u8, inner: []const u8 };
fn splitKeyed(data: []const u8) !KeyedSplit {
    var r = Reader{ .data = data, .pos = MAGIC_KEYED1.len };
    const present = try r.byte();
    const key: ?[]const u8 = if (present == 0) null else try r.str16();
    return .{ .key = key, .inner = data[r.pos..] };
}

/// Serialize a single-node create carrying an OPTIONAL idempotency key into a
/// GN1K wrapper around the legacy GNC1 body. A null key produces a wrapper whose
/// header marks "no key" (so it still dedups by index only, but travels through
/// the keyed apply path uniformly). The legacy keyless `serializeNodeCreate`
/// payload is unchanged and still decodes/applies through `applyNodeCreatePayloadKeyed`.
pub fn serializeNodeCreateKeyed(
    allocator: std.mem.Allocator,
    graph: []const u8,
    labels: []const []const u8,
    props: []const Prop,
    idempotency_key: ?[]const u8,
) ![]u8 {
    const inner = try serializeNodeCreate(allocator, graph, labels, props);
    defer allocator.free(inner);

    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, &MAGIC_KEYED1);
    try appendKeyHeader(&list, allocator, idempotency_key);
    try list.appendSlice(allocator, inner);
    return list.toOwnedSlice(allocator);
}

/// Apply a (keyed GN1K OR legacy keyless GNC1) single-node create with key-aware
/// dedup. Semantics:
///   * legacy GNC1 (no wrapper) -> applies EXACTLY like applyNodeCreatePayload
///     (index-keyed only); no key recorded.
///   * GN1K, no key             -> strips the wrapper, applies the inner GNC1
///     normally; no key recorded.
///   * GN1K, key NOT yet seen   -> records (key -> raft_index), then applies.
///   * GN1K, key seen at SAME index (restart replay) -> applies (index-idempotent).
///   * GN1K, key seen at a DIFFERENT index (CLIENT RETRY) -> NO-OP; returns the
///     ORIGINAL node id (== the original raft index for GNC1). No new row.
/// `dedup` persists across calls and is the cross-replica-deterministic oracle.
pub fn applyNodeCreatePayloadKeyed(
    allocator: std.mem.Allocator,
    store: *GraphStore,
    data: []const u8,
    raft_index: u64,
    dedup: *IdempotencyDedup,
) !u64 {
    // Legacy keyless GNC1 payload: behave exactly like applyNodeCreatePayload.
    if (isNodeCreatePayload(data)) {
        return applyNodeCreatePayload(allocator, store, data, raft_index);
    }
    if (data.len < MAGIC_KEYED1.len or !std.mem.eql(u8, data[0..MAGIC_KEYED1.len], &MAGIC_KEYED1))
        return CodecError.CorruptPayload;

    const split = try splitKeyed(data);
    if (split.key) |key| {
        if (dedup.lookup(key)) |orig_index| {
            // Same key already applied. Same index = restart replay (fall through
            // to the index-idempotent apply); different index = CLIENT RETRY ->
            // NO-OP, return the original node id (== original raft index, GNC1).
            if (orig_index != raft_index) return orig_index;
        } else {
            try dedup.record(key, raft_index);
        }
    }
    // Apply the unchanged inner GNC1 body at this entry's index (index-idempotent).
    return applyNodeCreatePayload(allocator, store, split.inner, raft_index);
}

/// Serialize a multi-create (N nodes + M edges) carrying an OPTIONAL idempotency
/// key into a GN2K wrapper around the legacy GNC2 body. See
/// serializeNodeCreateKeyed for the wrapper contract.
pub fn serializeMultiCreateKeyed(
    allocator: std.mem.Allocator,
    graph: []const u8,
    nodes: []const NodeSpec,
    edges: []const EdgeSpec,
    idempotency_key: ?[]const u8,
) ![]u8 {
    const inner = try serializeMultiCreate(allocator, graph, nodes, edges);
    defer allocator.free(inner);

    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, &MAGIC_KEYED2);
    try appendKeyHeader(&list, allocator, idempotency_key);
    try list.appendSlice(allocator, inner);
    return list.toOwnedSlice(allocator);
}

/// Apply a (keyed GN2K OR legacy keyless GNC2) multi-create with key-aware
/// dedup. Mirrors applyNodeCreatePayloadKeyed: a same-key-different-index retry
/// is a NO-OP (no duplicate nodes/edges), returning the original entity count;
/// a same-index replay or unseen key applies through applyMultiCreatePayload
/// (which is itself index-idempotent). `dedup` persists across calls.
pub fn applyMultiCreatePayloadKeyed(
    allocator: std.mem.Allocator,
    store: *GraphStore,
    data: []const u8,
    raft_index: u64,
    dedup: *IdempotencyDedup,
) !usize {
    // Legacy keyless GNC2 payload: behave exactly like applyMultiCreatePayload.
    if (isMultiCreatePayload(data)) {
        return applyMultiCreatePayload(allocator, store, data, raft_index);
    }
    if (data.len < MAGIC_KEYED2.len or !std.mem.eql(u8, data[0..MAGIC_KEYED2.len], &MAGIC_KEYED2))
        return CodecError.CorruptPayload;

    const split = try splitKeyed(data);
    if (split.key) |key| {
        if (dedup.lookup(key)) |orig_index| {
            // Different index = CLIENT RETRY -> NO-OP. Return the entity count the
            // original apply would have (decoded cheaply from the inner body) so
            // the caller sees a consistent "touched" total without re-creating.
            if (orig_index != raft_index) return countMultiCreateEntities(split.inner);
        } else {
            try dedup.record(key, raft_index);
        }
    }
    return applyMultiCreatePayload(allocator, store, split.inner, raft_index);
}

/// Count the (nodes + edges) a GNC2 body declares, WITHOUT applying it — used to
/// report a deduped-retry's touched-entity total. Returns 0 on a malformed body
/// (the retry is a no-op regardless).
fn countMultiCreateEntities(inner: []const u8) usize {
    if (!isMultiCreatePayload(inner)) return 0;
    var r = Reader{ .data = inner, .pos = MAGIC2.len };
    _ = r.str16() catch return 0; // graph
    const node_count = r.readU16() catch return 0;
    // We only need the counts; skip the node bodies to read the edge count.
    var k: usize = 0;
    while (k < node_count) : (k += 1) {
        const nlabels = r.readU16() catch return 0;
        var li: usize = 0;
        while (li < nlabels) : (li += 1) {
            _ = r.str16() catch return 0;
        }
        if (skipProps(&r) == false) return 0;
    }
    const edge_count = r.readU16() catch return 0;
    return @as(usize, node_count) + @as(usize, edge_count);
}

/// Advance `r` past one appendProps-encoded prop list. Returns false on a
/// malformed body.
fn skipProps(r: *Reader) bool {
    const n = r.readU16() catch return false;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        _ = r.str16() catch return false; // key
        const tag = r.byte() catch return false;
        switch (tag) {
            0 => {},
            1, 2 => _ = r.readU64() catch return false,
            3 => _ = r.byte() catch return false,
            4 => _ = r.str32() catch return false,
            else => return false,
        }
    }
    return true;
}

// ===========================================================================
// GBAT — one statement's writes as ONE committed entry (SONNY-3348, round 19)
// ===========================================================================
//
// A statement that writes once per row or per iteration (`FOR … CREATE`,
// `MATCH … MERGE`, a `CALL { … }` per row) proposed one entry per row, and
// waited for each to commit: when row 3 then failed (a limit, any error), rows
// 1 and 2 were committed on every node. The leader now holds a statement's
// entries (`statement_proposals`) and, once the whole statement evaluated
// without an error, proposes them as ONE entry: this GBAT batch, or the lone
// entry unchanged when there is only one. A statement that fails proposes
// nothing, and nothing proposed is ever undone.
//
// Every node applies a batch's entries in order through the same apply
// functions a lone entry takes. A create in a batch takes its ids from its
// position in the batch (`batchLaneBase`), not from the raft index alone, so
// two creates in one entry never share an id; the band is disjoint from the
// GNC1 (raft index) and GNC2 (`MULTI_ID_BASE`) bands and far below the
// time-based ids (`BATCH_ID_BASE` = 2^54; index i, position p use
// [2^54 + (i*4096 + p)*64, +63], below 2^56.7 for i < 3.8e11).
//
// VERSIONED, and refused cleanly by a build that does not know it: a batch is
// proposed as a `.create` mutation whose data starts with its own magic. A
// build before round 19 has no GBAT arm: its create dispatch sends an unknown
// magic to the "unknown create payload version — skipping" arm (raft_apply),
// which logs and applies nothing: no junk data, no partial statement. (A new
// mutation type would have been worse: the older decoder turns the byte into
// the enum unchecked.) A build that knows GBAT refuses a version it does not
// know the same way (`error.UnsupportedBatchVersion`, logged and skipped), and
// checks every entry of a batch before it applies any.
//
// The client's idempotency key rides the batch, not its entries: a retried
// statement is one no-op, while the entries of one statement (which share the
// request's key) are never taken for retries of each other.
//
// CANARY: REQ=REQ-SONNY-3348-CLUSTER-BATCH; FEATURE="DistributedCluster"; ASPECT=StatementBatchCodec; STATUS=TESTED; TEST=tests/test_sonny3348_cluster_batch.zig; OWNER=distributed; UPDATED=2026-09-29

/// 4-byte magic prefix identifying a GBAT statement batch.
pub const MAGIC_BATCH = [4]u8{ 'G', 'B', 'A', 'T' };

/// The batch format this build writes and applies.
pub const BATCH_VERSION: u8 = 1;

/// Most entries one batch carries (the lane windows per raft index).
pub const MAX_BATCH_ENTRIES: usize = 4096;

/// Most bytes one batch carries: a Raft entry is at most 1 MiB (the raft
/// library's `max_entry_size`), with room for the command's own header.
pub const MAX_BATCH_BYTES: usize = 1000 * 1024;

/// Bottom of the batch id band (see above).
pub const BATCH_ID_BASE: u64 = 1 << 54;

/// The mutation types a batch entry carries, as `raft_consensus.GraphMutation`
/// numbers them (create, update, delete, merge).
pub const BatchMutation = enum(u8) { create = 0, update = 1, delete = 2, merge = 3 };

pub const BatchError = error{UnsupportedBatchVersion};

/// The id window of the entry at `position` in the batch committed at
/// `raft_index`: node `k` of a create is `base + k`, edge `j` is
/// `base + MAX_MULTI_NODES + j`.
pub fn batchLaneBase(raft_index: u64, position: usize) u64 {
    std.debug.assert(position < MAX_BATCH_ENTRIES);
    return BATCH_ID_BASE + (raft_index * MAX_BATCH_ENTRIES + @as(u64, @intCast(position))) * MULTI_LANE_STRIDE;
}

pub fn isBatchPayload(data: []const u8) bool {
    return data.len >= MAGIC_BATCH.len and std.mem.eql(u8, data[0..MAGIC_BATCH.len], &MAGIC_BATCH);
}

/// One entry of a batch: what a lone proposal would have carried.
pub const BatchEntry = struct {
    mutation: BatchMutation,
    graph: []const u8,
    data: []const u8,
};

/// Serialize a statement's entries, in order, into one GBAT payload.
pub fn serializeBatch(allocator: std.mem.Allocator, idempotency_key: ?[]const u8, entries: []const BatchEntry) ![]u8 {
    if (entries.len == 0 or entries.len > MAX_BATCH_ENTRIES) return CodecError.UnsupportedPropertyType;
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, &MAGIC_BATCH);
    try list.append(allocator, BATCH_VERSION);
    try appendKeyHeader(&list, allocator, idempotency_key);
    try appendU32(&list, allocator, entries.len);
    for (entries) |e| {
        try list.append(allocator, @intFromEnum(e.mutation));
        try appendStr16(&list, allocator, e.graph);
        try appendU32(&list, allocator, e.data.len);
        try list.appendSlice(allocator, e.data);
    }
    if (list.items.len > MAX_BATCH_BYTES) return CodecError.UnsupportedPropertyType;
    return list.toOwnedSlice(allocator);
}

const ParsedBatch = struct {
    key: ?[]const u8,
    entries: []BatchEntry,
};

/// Decode and check a whole batch (borrowing into `data`), before any of it
/// is applied: its version, its bounds, and that each entry's payload is one
/// its mutation type applies.
fn parseBatch(allocator: std.mem.Allocator, data: []const u8) !ParsedBatch {
    if (!isBatchPayload(data)) return CodecError.CorruptPayload;
    var r = Reader{ .data = data, .pos = MAGIC_BATCH.len };
    const version = try r.byte();
    if (version != BATCH_VERSION) return BatchError.UnsupportedBatchVersion;
    const present = try r.byte();
    const key: ?[]const u8 = if (present == 0) null else try r.str16();
    const count = try r.readU32();
    if (count == 0 or count > MAX_BATCH_ENTRIES) return CodecError.CorruptPayload;
    const entries = try allocator.alloc(BatchEntry, count);
    errdefer allocator.free(entries);
    for (entries) |*e| {
        const tag = try r.byte();
        if (tag > @intFromEnum(BatchMutation.merge)) return CodecError.CorruptPayload;
        const mutation: BatchMutation = @enumFromInt(tag);
        const graph = try r.str16();
        const body = try r.str32();
        const ok = switch (mutation) {
            .create => isKeyedPayload(body) or isNodeCreatePayload(body) or isMultiCreatePayload(body),
            .update => isUpdatePayload(body),
            .delete => isDeletePayload(body),
            .merge => isMergePayload(body),
        };
        if (!ok) return CodecError.CorruptPayload;
        e.* = .{ .mutation = mutation, .graph = graph, .data = body };
    }
    if (r.pos != data.len) return CodecError.CorruptPayload;
    return .{ .key = key, .entries = entries };
}

/// SONNY-6631: call `f(ctx, graph, payload)` for each entry of a batch: the
/// graph it writes and its lone-entry payload (borrowing into `data`),
/// without allocating: the Raft receive paths hydrate the graphs and intern
/// the names before the apply. Stops at the first malformed entry
/// (its apply refuses the batch); a version this build does not know is
/// `UnsupportedBatchVersion`.
pub fn forEachBatchGraph(data: []const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const u8, []const u8) void) !void {
    if (!isBatchPayload(data)) return CodecError.CorruptPayload;
    var r = Reader{ .data = data, .pos = MAGIC_BATCH.len };
    if (try r.byte() != BATCH_VERSION) return BatchError.UnsupportedBatchVersion;
    if (try r.byte() != 0) _ = try r.str16();
    const count = try r.readU32();
    if (count == 0 or count > MAX_BATCH_ENTRIES) return CodecError.CorruptPayload;
    for (0..count) |_| {
        _ = try r.byte();
        const graph = try r.str16();
        f(ctx, graph, try r.str32());
    }
}

/// The number of entries a batch carries, or an error when it is not one
/// this build applies (tests, diagnostics).
pub fn batchEntryCount(allocator: std.mem.Allocator, data: []const u8) !usize {
    const parsed = try parseBatch(allocator, data);
    defer allocator.free(parsed.entries);
    return parsed.entries.len;
}

/// Apply a GBAT batch committed at `raft_index`: every entry in order, as a
/// lone entry of its kind applies. Returns the number of entries applied (0
/// for a retried statement the idempotency key recognizes). `dedup` is the
/// cluster's key table (null: keys are not checked).
pub fn applyBatchPayload(
    allocator: std.mem.Allocator,
    store: *GraphStore,
    data: []const u8,
    raft_index: u64,
    dedup: ?*IdempotencyDedup,
) !usize {
    const parsed = try parseBatch(allocator, data);
    defer allocator.free(parsed.entries);
    if (parsed.key) |key| {
        if (dedup) |d| {
            if (d.lookup(key)) |orig_index| {
                // The same statement, retried: it was applied at `orig_index`.
                if (orig_index != raft_index) return 0;
            } else {
                try d.record(key, raft_index);
            }
        }
    }
    for (parsed.entries, 0..) |e, position| {
        switch (e.mutation) {
            .create => {
                // The request's key is the batch's; the entry's own is not
                // checked (the entries of one statement share it).
                const body = if (isKeyedPayload(e.data)) (try splitKeyed(e.data)).inner else e.data;
                const base = batchLaneBase(raft_index, position);
                if (isNodeCreatePayload(body)) {
                    _ = try applyNodeCreatePayload(allocator, store, body, base);
                } else if (isMultiCreatePayload(body)) {
                    _ = try applyMultiCreatePayloadAt(allocator, store, body, base);
                } else return CodecError.CorruptPayload;
            },
            .update => _ = try applyUpdatePayload(allocator, store, e.data),
            .delete => _ = try applyDeletePayload(allocator, store, e.data),
            .merge => _ = try applyMergePayload(allocator, store, e.data),
        }
    }
    return parsed.entries.len;
}

/// A node an entry creates: its labels and properties (borrowed).
pub const CreatedNode = struct {
    labels: []const []const u8,
    props: []const Prop,
};

/// What an entry does, as the leader needs to know it to decide whether a
/// later read in the same statement would have seen it (borrowed from the
/// payload; the lists are `allocator`'s).
pub const Effect = struct {
    graph: []const u8 = "",
    created: []const CreatedNode = &.{},
    creates_edges: bool = false,
    deletes_edges: bool = false,
    /// The existing nodes and edges the entry changes, deletes, or links to.
    ids: []const u64 = &.{},
    /// Property keys and labels it sets or removes on existing nodes.
    written_keys: []const []const u8 = &.{},
    written_labels: []const []const u8 = &.{},
    /// SONNY-6633 (4): relationship types the entry creates edges with.
    edge_types: []const []const u8 = &.{},
};

fn readProps(allocator: std.mem.Allocator, r: *Reader) ![]const Prop {
    const n = try r.readU16();
    const props = try allocator.alloc(Prop, n);
    for (props) |*p| p.* = try readProp(r);
    return props;
}

fn readLabels(allocator: std.mem.Allocator, r: *Reader) ![]const []const u8 {
    const n = try r.readU16();
    const labels = try allocator.alloc([]const u8, n);
    for (labels) |*l| l.* = try r.str16();
    return labels;
}

/// Decode what the lone-entry payload `data` does. `allocator` should be an
/// arena: the lists are not freed one by one.
pub fn effectOf(allocator: std.mem.Allocator, data: []const u8) !Effect {
    if (isKeyedPayload(data)) return effectOf(allocator, (try splitKeyed(data)).inner);
    var out: Effect = .{};
    var ids = std.ArrayList(u64).empty;
    var keys = std.ArrayList([]const u8).empty;
    var labels = std.ArrayList([]const u8).empty;
    var edge_types = std.ArrayList([]const u8).empty;
    if (isNodeCreatePayload(data)) {
        var r = Reader{ .data = data, .pos = MAGIC.len };
        out.graph = try r.str16();
        const created = try allocator.alloc(CreatedNode, 1);
        created[0] = .{ .labels = try readLabels(allocator, &r), .props = try readProps(allocator, &r) };
        out.created = created;
    } else if (isMultiCreatePayload(data)) {
        var r = Reader{ .data = data, .pos = MAGIC2.len };
        out.graph = try r.str16();
        const node_count = try r.readU16();
        const created = try allocator.alloc(CreatedNode, node_count);
        for (created) |*c| c.* = .{ .labels = try readLabels(allocator, &r), .props = try readProps(allocator, &r) };
        out.created = created;
        const edge_count = try r.readU16();
        out.creates_edges = edge_count > 0;
        var j: usize = 0;
        while (j < edge_count) : (j += 1) {
            for ([_]Endpoint{ try readEndpoint(&r), try readEndpoint(&r) }) |ep| {
                if (ep == .absolute_id) try ids.append(allocator, ep.absolute_id);
            }
            try edge_types.append(allocator, try r.str16());
            _ = try readProps(allocator, &r);
        }
    } else if (isDeletePayload(data)) {
        var r = Reader{ .data = data, .pos = MAGIC_DEL.len };
        out.graph = try r.str16();
        const edge_count = try r.readU16();
        out.deletes_edges = edge_count > 0;
        var i: usize = 0;
        while (i < edge_count) : (i += 1) try ids.append(allocator, try r.readU64());
        const node_count = try r.readU16();
        i = 0;
        while (i < node_count) : (i += 1) try ids.append(allocator, try r.readU64());
    } else if (isMergePayload(data)) {
        var r = Reader{ .data = data, .pos = MAGIC_MERGE.len };
        out.graph = try r.str16();
        try ids.append(allocator, try r.readU64());
        for (try readProps(allocator, &r)) |p| try keys.append(allocator, p.key);
    } else if (isUpdatePayload(data)) {
        var r = Reader{ .data = data, .pos = MAGIC_UPDATE.len };
        out.graph = try r.str16();
        const count = try r.readU16();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try ids.append(allocator, try r.readU64());
            for (try readProps(allocator, &r)) |p| try keys.append(allocator, p.key);
            for (try readLabels(allocator, &r)) |k| try keys.append(allocator, k);
            for (try readLabels(allocator, &r)) |l| try labels.append(allocator, l);
            for (try readLabels(allocator, &r)) |l| try labels.append(allocator, l);
        }
    } else return CodecError.CorruptPayload;
    out.ids = ids.items;
    out.written_keys = keys.items;
    out.written_labels = labels.items;
    out.edge_types = edge_types.items;
    return out;
}

// ===========================================================================
// SONNY-2726 — the writing session's tenant rides the replicated entry
// ===========================================================================
//
// A replicated write is applied by the raft apply thread, which has no
// request context, so every node and edge it created was tagged with the
// default tenant on every node, and (since SONNY-2693's strict edge rule) a
// tenant's replicated edges were hidden from it. The leader now wraps the
// entry of a session whose tenant is not the default in a GTN1 envelope:
//
//   "GTN1" | str16 tenant | the unchanged inner payload (any graph-mutation
//                           payload: GNC1/GNC2/GN1K/GN2K/GBAT/delete/merge/update)
//
// and the apply creates under that tenant. A default-tenant write is not
// wrapped, so it is byte-identical to before, and entries already in the log
// (no envelope) still apply as the default tenant. A node running a build
// without this envelope logs and skips a GTN1 create (its unknown-magic arm)
// and cannot decode a wrapped delete/merge/update: upgrade every node before
// tenant-scoped sessions write in a cluster.
//
// CANARY: REQ=REQ-SONNY-2726-REPLICATED-TENANT; FEATURE="DistributedCluster"; ASPECT=TenantEnvelope; STATUS=TESTED; TEST=tests/test_sonny2726_replicated_tenant.zig; OWNER=distributed; UPDATED=2026-11-12

/// 4-byte magic prefix of the tenant envelope.
pub const MAGIC_TENANT = [4]u8{ 'G', 'T', 'N', '1' };

/// True iff `data` is a GTN1 tenant envelope.
pub fn isTenantPayload(data: []const u8) bool {
    return data.len >= MAGIC_TENANT.len and std.mem.eql(u8, data[0..MAGIC_TENANT.len], &MAGIC_TENANT);
}

/// Wrap `inner` in a GTN1 envelope naming `tenant` (non-empty, at most
/// 65535 bytes, else UnsupportedPropertyType). Caller owns the result.
pub fn wrapWithTenant(allocator: std.mem.Allocator, tenant: []const u8, inner: []const u8) ![]u8 {
    if (tenant.len == 0) return CodecError.UnsupportedPropertyType;
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, &MAGIC_TENANT);
    try appendStr16(&list, allocator, tenant);
    try list.appendSlice(allocator, inner);
    return list.toOwnedSlice(allocator);
}

pub const TenantSplit = struct { tenant: []const u8, inner: []const u8 };

/// Split a GTN1 envelope into its tenant and inner payload (both borrowed
/// from `data`). An empty tenant or a nested envelope is CorruptPayload.
pub fn splitTenant(data: []const u8) !TenantSplit {
    if (!isTenantPayload(data)) return CodecError.CorruptPayload;
    var r = Reader{ .data = data, .pos = MAGIC_TENANT.len };
    const tenant = try r.str16();
    if (tenant.len == 0) return CodecError.CorruptPayload;
    const inner = data[r.pos..];
    if (isTenantPayload(inner)) return CodecError.CorruptPayload;
    return .{ .tenant = tenant, .inner = inner };
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
