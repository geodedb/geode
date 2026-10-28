const std = @import("std");
const graph_store = @import("../graph_store.zig");
const index_manager = @import("../index/index_manager.zig");
const property_codec = @import("../property_value_codec.zig");
const value_types = @import("../value_types.zig");
const decimal_text = @import("../types/decimal_text.zig");
const fle_hooks = @import("fle_hooks.zig");
// A4b: fulltext write-maintenance hook (delete-then-index on SET).
const fts_index_ops = @import("fts_index_ops.zig");

const log = std.log.scoped(.property_mutation);

// CANARY: REQ=REQ-ADV-TYPE-MIGRATION-001; FEATURE="AdvancedPropertyMigration"; ASPECT=ExecutionMutation; STATUS=IMPL; OWNER=engine; UPDATED=2026-04-01
const json_lib = @import("json");
const jsonb = @import("../types/jsonb.zig");

const Value = value_types.Value;

/// SONNY-2769: at any scale. `pow *= 10` overflowed past scale 38 and aborted
/// the server (`SET n.m = {a: <a scale-40 decimal>}`), and a value between -1
/// and 0 was stored without its sign (-0.5 as 0.5).
fn formatDecimalForJson(allocator: std.mem.Allocator, coeff: i128, scale: u8) ![]const u8 {
    return decimal_text.alloc(allocator, coeff, scale);
}

fn encodeExtValueToStream(allocator: std.mem.Allocator, ext: property_codec.ExtValue, encoder: anytype) !void {
    switch (ext) {
        .Null => try encoder.writeNull(),
        .Int => |i| try encoder.writeInt(i),
        .Bool => |b| try encoder.writeBool(b),
        .Str => |s| try encoder.writeString(s),
        .Decimal => |d| {
            const decimal_str = try formatDecimalForJson(allocator, d.coeff, d.scale);
            defer allocator.free(decimal_str);
            try encoder.writeRaw(decimal_str);
        },
        .SmallInt => |i| try encoder.writeInt(i),
        .BigInt => |i| try encoder.writeInt(i),
        .Real => |f| try encoder.writeFloat(f),
        .Double => |f| try encoder.writeFloat(f),
        .Char => |c| try encoder.writeString(c.data),
        .Varchar => |v| try encoder.writeString(v.data),
        .Text => |t| try encoder.writeString(t),
        .Json => |j| try encoder.writeRaw(j),
        .Jsonb => |j| try encoder.writeRaw(j.data),
        .List => |list| {
            try encoder.beginArray();
            for (list) |item| {
                try encodeExtValueToStream(allocator, item, encoder);
            }
            try encoder.endArray();
        },
        else => try encoder.writeNull(),
    }
}

fn encodeValueToStream(allocator: std.mem.Allocator, value: Value, encoder: anytype) !void {
    switch (value) {
        .Null => try encoder.writeNull(),
        .Int => |i| try encoder.writeInt(i),
        .Bool => |b| try encoder.writeBool(b),
        .Str => |s| try encoder.writeString(s),
        .Decimal => |d| {
            const decimal_str = try formatDecimalForJson(allocator, d.coeff, d.scale);
            defer allocator.free(decimal_str);
            try encoder.writeRaw(decimal_str);
        },
        .SmallInt => |i| try encoder.writeInt(i),
        .BigInt => |i| try encoder.writeInt(i),
        .Real => |f| try encoder.writeFloat(f),
        .Double => |f| try encoder.writeFloat(f),
        .Char => |c| try encoder.writeString(c.data),
        .Varchar => |v| try encoder.writeString(v.data),
        .Text => |t| try encoder.writeString(t),
        .Json => |j| try encoder.writeRaw(j),
        .Jsonb => |j| try encoder.writeRaw(j.data),
        .List => |list| {
            try encoder.beginArray();
            for (list) |item| {
                try encodeValueToStream(allocator, item, encoder);
            }
            try encoder.endArray();
        },
        .Map => |map| {
            try encoder.beginObject();
            var iter = map.iterator();
            while (iter.next()) |entry| {
                try encoder.writeKey(entry.key_ptr.*);
                try encodeValueToStream(allocator, entry.value_ptr.*, encoder);
            }
            try encoder.endObject();
        },
        .ExtValue => |ext| try encodeExtValueToStream(allocator, ext, encoder),
        else => try encoder.writeNull(),
    }
}

fn valueMapToJson(allocator: std.mem.Allocator, map: std.StringHashMap(Value)) ![]const u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer aw.deinit();

    var encoder = json_lib.streamingEncoder(allocator, &aw.writer, .{});
    try encoder.beginObject();

    var iter = map.iterator();
    while (iter.next()) |entry| {
        try encoder.writeKey(entry.key_ptr.*);
        try encodeValueToStream(allocator, entry.value_ptr.*, &encoder);
    }

    try encoder.endObject();
    return try allocator.dupe(u8, aw.written());
}

/// Update advanced indexes for a single property mutation.
/// Only triggers a rebuild when an advanced index (vector, spatial, CIDR, etc.)
/// is actually registered for this label+property combination.
/// GAP-0511: Previously called on every setNodeProperty, causing a full O(N)
/// index drop+rebuild under the graph write lock per property set. Now checks
/// hasAdvancedIndexForProperty first — O(1) hash map probe that short-circuits
/// for the common case (no advanced index on the mutated property).
fn rebuildAdvancedIndexesForProperty(
    store: *graph_store.GraphStore,
    label: []const u8,
    property: []const u8,
) void {
    const manager = index_manager.getGlobalIndexManager() orelse return;
    if (!manager.hasAdvancedIndexForProperty(label, property)) return;

    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(store.allocator);

    var iter = manager.advanced_property_indexes.iterator();
    while (iter.next()) |entry| {
        const meta = entry.value_ptr.*;
        if (std.mem.eql(u8, meta.label, label) and std.mem.eql(u8, meta.property, property)) {
            names.append(store.allocator, meta.name) catch continue;
        }
    }

    queueAdvancedIndexRebuild(store, manager, &names);
}

// GAP-0815: Public wrapper so the batch-CREATE fast path in
// `crud_operations.zig` can trigger the same once-per-(label,key)
// advanced-index rebuild logic as the serial `setNodePropertyFromValue`
// path, without duplicating the short-circuit check.
pub fn rebuildAdvancedIndexesForPropertyPublic(
    store: *graph_store.GraphStore,
    label: []const u8,
    property: []const u8,
) void {
    rebuildAdvancedIndexesForProperty(store, label, property);
}

/// geode#875 RC-1: keep advanced indexes current for a single node property
/// write. In the AUTOCOMMIT / non-transactional path this is an INCREMENTAL
/// HNSW insert of the one changed node — NOT the O((K+M)·M) full drop+rebuild
/// the write path used to run per write (133 s for a single write at 24 k).
/// Falls back to a full rebuild when:
///   * a deferred rebuild context is active (an open txn undo log, or a
///     per-statement pending-rebuild set) — the deferred rebuild dedupes AND is
///     the only rollback-safe path (HNSW cannot un-insert on rollback), or
///   * the incremental insert declines (an OVERWRITE of an already-indexed id, a
///     non-vector index type, or a value that does not coerce to a vector).
fn maintainAdvancedIndexesForNodeWrite(
    store: *graph_store.GraphStore,
    label: []const u8,
    property: []const u8,
    node_id: u64,
    prop: graph_store.PropertyValue,
) void {
    const manager = index_manager.getGlobalIndexManager() orelse return;
    if (!manager.hasAdvancedIndexForProperty(label, property)) return;

    if (advancedIndexRebuildIsDeferred(store, manager, label, property)) {
        rebuildAdvancedIndexesForProperty(store, label, property);
        return;
    }

    if (!manager.tryIncrementalInsertForProperty(label, property, node_id, prop)) {
        rebuildAdvancedIndexesForProperty(store, label, property);
    }
}

/// True when a node property write's advanced-index maintenance must be
/// DEFERRED to a batched full rebuild instead of taking the incremental insert.
/// Mirrors the branch selection in `queueAdvancedIndexRebuild`. Two cases:
///
///   * an open txn undo log — the deferred rebuild is the only rollback-safe
///     path, because HNSW cannot un-insert on rollback; and
///   * this statement ALREADY queued a full rebuild of an index covering
///     (label, property) — i.e. a CREATE INDEX whose backfill is deliberately
///     deferred out of the exclusive write lock. Racing an incremental insert
///     against that pending build would either be discarded by it or duplicate
///     a row it also inserts.
///
/// geode#875 RC-1b: this used to short-circuit on the mere PRESENCE of
/// `ctx.pending_index_rebuilds`, which the QUIC and gRPC handlers install for
/// EVERY statement — so `tryIncrementalInsertForProperty` was unreachable on
/// any real connection and every single write to an indexed vector property
/// queued a full O(N) drop+rebuild (measured 100 s for ONE write at
/// 3 000 x 256 dims). The queue being INSTALLED is not the signal; the queue
/// holding a rebuild for THIS property is.
fn advancedIndexRebuildIsDeferred(
    store: *graph_store.GraphStore,
    manager: *index_manager.IndexManager,
    label: []const u8,
    property: []const u8,
) bool {
    const txn_undo_log = @import("../txn_undo_log.zig");
    if (txn_undo_log.getGlobalUndoLog(store.allocator).active) return true;
    const execution = @import("../execution.zig");
    if (execution.getActiveContext()) |ctx| {
        if (ctx.pending_index_rebuilds) |rebuilds| {
            if (rebuilds.count() == 0) return false;
            var iter = manager.advanced_property_indexes.iterator();
            while (iter.next()) |entry| {
                const meta = entry.value_ptr.*;
                if (!std.mem.eql(u8, meta.label, label) or !std.mem.eql(u8, meta.property, property)) continue;
                if (rebuilds.contains(meta.name)) return true;
            }
        }
    }
    return false;
}

fn rebuildAdvancedIndexesForLabel(store: *graph_store.GraphStore, label: []const u8) void {
    const manager = index_manager.getGlobalIndexManager() orelse return;
    if (!manager.hasAdvancedIndexForLabel(label)) return;

    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(store.allocator);

    var iter = manager.advanced_property_indexes.iterator();
    while (iter.next()) |entry| {
        const meta = entry.value_ptr.*;
        if (std.mem.eql(u8, meta.label, label)) {
            names.append(store.allocator, meta.name) catch continue;
        }
    }

    queueAdvancedIndexRebuild(store, manager, &names);
}

fn queueAdvancedIndexRebuild(
    store: *graph_store.GraphStore,
    manager: *@import("../index/index_manager.zig").IndexManager,
    names: *std.ArrayList([]const u8),
) void {
    if (names.items.len == 0) return;

    const txn_undo_log = @import("../txn_undo_log.zig");
    const undo_log = txn_undo_log.getGlobalUndoLog(store.allocator);
    if (undo_log.active) {
        for (names.items) |name| {
            undo_log.queueAdvancedIndexRebuild(name) catch |err| {
                // error-policy: B — a dropped rebuild entry leaves the advanced
                // index stale after the txn resolves; the mutation itself is
                // committed/rolled back independently, so log loudly.
                log.warn("failed to queue advanced index rebuild for '{s}': {s}", .{ name, @errorName(err) });
            };
        }
        return;
    }

    const execution = @import("../execution.zig");
    if (execution.getActiveContext()) |ctx| {
        if (ctx.pending_index_rebuilds) |rebuilds| {
            // Use the same allocator that will free the keys (gpa in QUIC handler).
            // Using store.allocator here would cause Invalid free when gpa frees them.
            const alloc = ctx.pending_index_rebuilds_allocator orelse store.allocator;
            for (names.items) |name| {
                // error-policy: B — an OOM here drops the pending rebuild and
                // leaves the advanced index stale; log loudly and continue.
                const name_copy = alloc.dupe(u8, name) catch {
                    log.warn("failed to queue pending index rebuild for '{s}': OutOfMemory", .{name});
                    continue;
                };
                rebuilds.put(name_copy, {}) catch {
                    alloc.free(name_copy);
                    log.warn("failed to queue pending index rebuild for '{s}': OutOfMemory", .{name});
                };
            }
            return;
        }
    }

    // SONNY-3319: the names are the index manager's own strings, and a
    // rebuild that fails drops its index and frees them; the log line below
    // then read freed memory (the next vector SET after a wrong-dimension one
    // crashed). Every name is copied before any rebuild runs.
    for (names.items) |*name| {
        name.* = store.allocator.dupe(u8, name.*) catch {
            log.warn("failed to copy advanced index name for rebuild: OutOfMemory", .{});
            name.* = "";
            continue;
        };
    }
    defer for (names.items) |name| {
        if (name.len != 0) store.allocator.free(name);
    };
    for (names.items) |name| {
        if (name.len == 0) continue;
        manager.rebuildAdvancedIndex(store, name) catch |err| {
            // error-policy: B — a failed rebuild leaves the advanced index
            // stale (queries may serve stale entries); the mutation itself
            // committed, so log loudly instead of failing the statement.
            log.warn("advanced index rebuild failed for '{s}': {s}", .{ name, @errorName(err) });
        };
    }
}

pub fn coercePropertyValue(allocator: std.mem.Allocator, value: Value) !graph_store.PropertyValue {
    return switch (value) {
        .Map => |map| blk: {
            const json_str = try valueMapToJson(allocator, map);
            defer allocator.free(json_str);

            const doc = try jsonb.JsonbDocument.fromString(allocator, json_str);
            break :blk .{ .ExtValue = .{ .Jsonb = doc } };
        },
        else => try property_codec.valueToPropertyValue(allocator, value),
    };
}

pub fn clearNodeProperties(store: *graph_store.GraphStore, node: *graph_store.Node) void {
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(store.allocator);

    var prop_iter = node.properties.iterator();
    while (prop_iter.next()) |prop_entry| {
        keys.append(store.allocator, prop_entry.key_ptr.*) catch return;
    }

    for (keys.items) |key| {
        store.removeNodeProperty(node.id, key);
    }
}

pub fn clearEdgeProperties(store: *graph_store.GraphStore, edge: *graph_store.Edge) void {
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(store.allocator);

    var prop_iter = edge.properties.iterator();
    while (prop_iter.next()) |prop_entry| {
        keys.append(store.allocator, prop_entry.key_ptr.*) catch return;
    }

    for (keys.items) |key| {
        store.removeEdgeProperty(edge.id, key);
    }
}

pub fn setNodePropertyFromValue(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    caller_labels: [][]const u8,
    node_id: u64,
    key: []const u8,
    value: Value,
) !void {
    // GAP-0854 follow-up: resolve the node's graph so the FLE hook can exclude
    // the internal __geode_security graph. Cheap pointer lookup; the security
    // graph must never receive an FLE envelope (its records feed the auth HMAC
    // chain, which is computed over plaintext).
    const resident = store.getNodePtr(node_id);
    const node_graph: ?[]const u8 = if (resident) |n| n.graph_name else null;
    // CANARY: REQ=REQ-SONNY-3319-CURRENT-LABELS; FEATURE="VectorIndex"; ASPECT=WriteChokepointLabels; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-28
    // SONNY-3319: the node's labels as they are now, not as the caller read
    // them: a SET that adds a label earlier in the same clause (`SET n:VD,
    // n.emb = <2-dim vector>`) passed the labels from before the clause, so
    // the dimension guard and the FLE hook below did not see `:VD` and a
    // wrong-dimension vector went into VD's HNSW index. The caller's labels
    // are used only for a node that is not resident.
    const labels: [][]const u8 = if (resident) |n| n.labels else caller_labels;

    // CANARY: REQ=REQ-GAP-0918-VECTOR-INDEX-VALIDATION; FEATURE="VectorIndex"; ASPECT=WriteChokepoint; STATUS=TESTED; TEST=tests/test_gap0918_vector_validation.zig; OWNER=index; UPDATED=2026-07-10
    // GAP-0918: reject dimension-mismatched vectors before they reach an
    // HNSW-indexed property (this is the single chokepoint for all node
    // property writes: CREATE, MATCH...SET, MERGE ON CREATE/MATCH).
    switch (value) {
        .ExtValue => |ev| {
            if (ev == .VectorF32) {
                // ENG-3912(d): arm the guard from the catalog if this process
                // has not seen the CREATE INDEX (e.g. after a restart).
                const statement_dispatcher = @import("statement_dispatcher.zig");
                try statement_dispatcher.armVectorDimGuard(allocator, labels, key);
            }
        },
        else => {},
    }
    // CANARY: REQ=REQ-ENG-3922-VECTOR-DIM-GUARD; FEATURE="VectorIndex"; ASPECT=UnindexedDimWriteCheck; STATUS=TESTED; TEST=tests/test_eng3922_dim_guard.zig; OWNER=index; UPDATED=2026-08-29
    // ENG-3922(a): the same check now also covers an (label, property) with NO
    // vector index, scoped to the node's own graph (`node_graph`, already
    // resolved above — the most precise answer available at this point, since
    // the node exists).
    switch (value) {
        .ExtValue => |ev| {
            if (ev == .VectorF32) {
                if (index_manager.ensureGlobalIndexManagerForDimGuard()) |mgr| {
                    // The row this write REPLACES must not testify against its
                    // own replacement — a re-embedding SET on the sole holder
                    // was permanently refused before the exclusion.
                    try mgr.checkVectorDimensionForWriteInGraphExcluding(node_graph, labels, key, ev.VectorF32.dim, node_id);
                }
            }
        },
        else => {},
    }

    const prop_value = switch (value) {
        .Str => |s| blk: {
            const encrypted_or_plain = try fle_hooks.encryptPropertyIfNeeded(
                allocator,
                node_graph,
                labels,
                key,
                s,
                node_id,
            );
            defer if (encrypted_or_plain.ptr != s.ptr or encrypted_or_plain.len != s.len) allocator.free(encrypted_or_plain);
            break :blk graph_store.PropertyValue{ .String = try allocator.dupe(u8, encrypted_or_plain) };
        },
        else => try coercePropertyValue(allocator, value),
    };
    defer property_codec.freePropertyValue(allocator, prop_value);

    // Property-write atomicity, defence in depth: the statement-level pre-pass
    // (execution/write_precheck.zig) is what actually makes a statement
    // all-or-nothing, but this is the single chokepoint every node property
    // write passes through, so refusing an unstorable entry here too keeps a
    // future write path that forgets its pre-pass from writing a partial
    // statement. Post-FLE, so the encrypted size is what gets measured.
    // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=WriteChokepoint; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
    if (graph_store.getGlobalAdapter()) |adapter| {
        try adapter.checkPropertyEntryWritable(key, prop_value);
    }

    try store.setNodeProperty(node_id, key, prop_value);

    // CANARY: REQ=REQ-ENG-3912-VECTOR-DIM-LIFECYCLE; FEATURE="VectorIndex"; ASPECT=DimAdoptAfterCommit; STATUS=TESTED; TEST=tests/test_eng3912_dim_pinning.zig; OWNER=index; UPDATED=2026-08-25
    // ENG-3912(a): establish the vector-dimension pin only AFTER the write has
    // committed. The validation pre-pass used to adopt the dimension as a side
    // effect of merely CHECKING it, so a statement that was subsequently
    // refused still pinned the property forever (verified: a refused mixed-dim
    // CREATE bricked an EMPTY property).
    if (index_manager.getGlobalIndexManager()) |mgr| {
        switch (value) {
            .ExtValue => |ev| {
                if (ev == .VectorF32) {
                    mgr.adoptVectorDimensionInGraph(node_graph, labels, key, ev.VectorF32.dim);
                    // A committed overwrite that legitimately re-dimensioned
                    // the sole holder moves the established unindexed pin with
                    // it (adopt only fills unestablished pins).
                    mgr.repinUnindexedVectorDimsInGraph(node_graph, labels, key, ev.VectorF32.dim);
                }
            },
            else => {},
        }
    }

    if (labels.len > 0) maintainAdvancedIndexesForNodeWrite(store, labels[0], key, node_id, prop_value);

    // A4b: keep fulltext indexes current. This is the single property-write
    // chokepoint for ALL node SET paths (CREATE…SET, MATCH…SET, MERGE ON
    // CREATE/MATCH, replaceNodeProperties), so hooking here covers them all with
    // one call. Cheap-exits when no FTS index covers `labels`. Graph is resolved
    // from the node id inside the helper (no graph in scope here). Runs on the
    // executor/connection thread — the same thread that owns the fts engine
    // (verified: setNodePropertyFromValue is never called from bulkMergeNode or
    // any worker thread).
    // `.upsert` (append-only) — NOT `.update`. The fts-storage engine adds a
    // doc_id to `all_tombstones` on deleteDocument and NEVER removes it on a
    // later indexDocument (the set is only rebuilt from segments on reopen/
    // compaction). So `.update` (deleteNode-then-reindex on the SAME node_id)
    // left the re-indexed document filtered out by search → the 2026-06-07
    // "zero results" bug for live CREATE/SET. `.upsert` skips the tombstone so
    // the document is immediately searchable.
    //
    // KNOWN RESIDUAL (tracked, not self-healing): a TRUE value change via SET on
    // an already-indexed node leaves the OLD value's postings in place (no
    // tombstone), so the node stays findable by the stale old value, and
    // repeated SETs append-grow the index. Search-for-current-value is correct;
    // reclaiming stale postings needs an engine-level un-tombstone-on-reindex
    // (or a compaction trigger) — see
    // docs/bugs/2026-06-07-fts-search-returns-zero-results-at-runtime.md.
    fts_index_ops.maintainFulltextOnWrite(allocator, null, node_id, labels, .upsert) catch |err| {
        log.warn("fts maintain (SET) failed for node {d} prop '{s}': {}", .{ node_id, key, err });
    };
}

pub fn setEdgePropertyFromValue(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    edge_type: []const u8,
    edge_id: u64,
    key: []const u8,
    value: Value,
) !void {
    // GAP-0854 follow-up: resolve the edge's graph so the FLE hook can exclude
    // the internal __geode_security graph (HAS_ROLE etc. feed the auth chain).
    const edge_graph: ?[]const u8 = if (store.getEdgePtr(edge_id)) |e| e.graph_name else null;
    const prop_value = switch (value) {
        .Str => |s| blk: {
            const encrypted_or_plain = try fle_hooks.encryptEdgePropertyIfNeeded(
                allocator,
                edge_graph,
                edge_type,
                key,
                s,
                edge_id,
            );
            defer if (encrypted_or_plain.ptr != s.ptr or encrypted_or_plain.len != s.len) allocator.free(encrypted_or_plain);
            break :blk graph_store.PropertyValue{ .String = try allocator.dupe(u8, encrypted_or_plain) };
        },
        else => try coercePropertyValue(allocator, value),
    };
    defer property_codec.freePropertyValue(allocator, prop_value);

    // Property-write atomicity, defence in depth — see setNodePropertyFromValue.
    // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=WriteChokepoint; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
    if (graph_store.getGlobalAdapter()) |adapter| {
        try adapter.checkPropertyEntryWritable(key, prop_value);
    }

    try store.setEdgeProperty(edge_id, key, prop_value);
    rebuildAdvancedIndexesForProperty(store, edge_type, key);
}

pub fn replaceNodeProperties(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    node: *graph_store.Node,
    props_value: Value,
) !void {
    clearNodeProperties(store, node);

    if (props_value != .Map) return;

    var map_iter = props_value.Map.iterator();
    while (map_iter.next()) |entry| {
        try setNodePropertyFromValue(
            allocator,
            store,
            node.labels,
            node.id,
            entry.key_ptr.*,
            entry.value_ptr.*,
        );
    }

    if (node.labels.len > 0) rebuildAdvancedIndexesForLabel(store, node.labels[0]);
}

pub fn replaceEdgeProperties(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    edge: *graph_store.Edge,
    props_value: Value,
) !void {
    clearEdgeProperties(store, edge);

    if (props_value != .Map) return;

    var map_iter = props_value.Map.iterator();
    while (map_iter.next()) |entry| {
        try setEdgePropertyFromValue(
            allocator,
            store,
            edge.label,
            edge.id,
            entry.key_ptr.*,
            entry.value_ptr.*,
        );
    }

    rebuildAdvancedIndexesForLabel(store, edge.label);
}

pub fn removeNodeProperty(
    store: *graph_store.GraphStore,
    node: *graph_store.Node,
    key: []const u8,
) void {
    store.removeNodeProperty(node.id, key);
    if (node.labels.len > 0) rebuildAdvancedIndexesForProperty(store, node.labels[0], key);
}

pub fn removeEdgeProperty(
    store: *graph_store.GraphStore,
    edge: *graph_store.Edge,
    key: []const u8,
) void {
    store.removeEdgeProperty(edge.id, key);
    rebuildAdvancedIndexesForProperty(store, edge.label, key);
}
