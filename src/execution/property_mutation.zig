const std = @import("std");
const graph_store = @import("../graph_store.zig");
const index_manager = @import("../index/index_manager.zig");
const property_codec = @import("../property_value_codec.zig");
const value_types = @import("../value_types.zig");
const decimal_text = @import("../types/decimal_text.zig");
const fle_hooks = @import("fle_hooks.zig");
const fle_integration = @import("../fle_integration.zig"); // SONNY-6347
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

    // SONNY-6703: the node's own graph picks the indexes that take it; one
    // that cannot be read falls to the rebuild, which selects by graph.
    const node_graph: ?[]const u8 = if (store.nodes.getOrHydratePtr(node_id) catch null) |n| n.graph_name else null;
    if (!manager.tryIncrementalInsertForPropertyInGraph(node_graph, label, property, node_id, prop)) {
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
    // CANARY: REQ=REQ-SONNY-3245-NULL-PROPERTY-ABSENT; FEATURE="SetClauseSemantics"; ASPECT=NullRemovesProperty; STATUS=TESTED; TEST=tests/test_sonny3245_create_merge_forms.zig; OWNER=engine; UPDATED=2026-11-12
    // SONNY-3245: a property whose value is null is absent (GQL; the NOT NULL
    // constraint already reads it so). `SET n.p = null` kept p with a null
    // value and `CREATE (n {p: null})` stored it, so `keys(n)` named p.
    if (value == .Null) {
        const node = (try store.nodes.getOrHydratePtr(node_id)) orelse return error.NodeNotFound;
        if (node.properties.contains(key)) removeNodeProperty(store, node, key);
        return;
    }
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
            // SONNY-6347: the record's stored tenant is the encryption
            // identity's (hydrated here when the node is not resident).
            const record_tenant = if (resident) |n| n.tenant_id else if (try store.nodes.getOrHydratePtr(node_id)) |n| n.tenant_id else fle_integration.tenantPreferringActiveContext();
            const encrypted_or_plain = try fle_hooks.encryptPropertyIfNeeded(
                allocator,
                node_graph,
                labels,
                key,
                s,
                node_id,
                record_tenant,
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

    // SONNY-6421: the fulltext engine cannot take the old words out of the
    // node's document, so a replaced non-empty string queues every covering
    // index for a rebuild at the statement's end (as REMOVE n.prop does).
    const replaced_text = replacesText(store, node_id, key, prop_value);

    try store.setNodeProperty(node_id, key, prop_value);

    if (replaced_text) {
        const graph_name = node_graph orelse if (store.getNodePtr(node_id)) |n| n.graph_name else graph_store.DEFAULT_GRAPH_NAME;
        fts_index_ops.queueRebuildForRemovedText(graph_name, labels, key);
    }

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

    // CANARY: REQ=REQ-SONNY-6368-EVERY-LABEL; FEATURE="VectorIndex"; ASPECT=WriteChokepointEveryLabel; STATUS=TESTED; TEST=tests/test_sonny6368_index_maintenance.zig; OWNER=engine; UPDATED=2026-11-12
    // SONNY-6368: every label's indexes. Only the first label's were
    // maintained, so an index on a node's second label went stale.
    for (labels) |label| maintainAdvancedIndexesForNodeWrite(store, label, key, node_id, prop_value);

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
    // SONNY-6421: a TRUE value change leaves the OLD value's postings in this
    // append; the rebuild queued above (`replaced_text`) takes them out at the
    // statement's end, so the node is not found by the old words after the
    // statement.
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
    // SONNY-3245: a null value makes the property absent, as on a node.
    if (value == .Null) {
        const edge = (try store.getEdgePtrHydratedChecked(edge_id)) orelse return error.EdgeNotFound;
        if (edge.properties.contains(key)) removeEdgeProperty(store, edge, key);
        return;
    }
    // GAP-0854 follow-up: resolve the edge's graph so the FLE hook can exclude
    // the internal __geode_security graph (HAS_ROLE etc. feed the auth chain).
    const edge_graph: ?[]const u8 = if ((try store.getEdgePtrHydratedChecked(edge_id))) |e| e.graph_name else null;
    const prop_value = switch (value) {
        .Str => |s| blk: {
            // SONNY-6347: the record's stored tenant is the encryption identity's.
            // SONNY-6567 (2): an edge that cannot be read fails the write; it
            // was encrypted under the session's tenant instead of its own.
            const record_tenant = if (try store.getEdgePtrHydratedChecked(edge_id)) |e| e.tenant_id else fle_integration.tenantPreferringActiveContext();
            const encrypted_or_plain = try fle_hooks.encryptEdgePropertyIfNeeded(
                allocator,
                edge_graph,
                edge_type,
                key,
                s,
                edge_id,
                record_tenant,
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

// CANARY: REQ=REQ-SONNY-6705-SET-ALL-FROM-ELEMENT; FEATURE="SetClauseSemantics"; ASPECT=SetAllFromElement; STATUS=TESTED; TEST=tests/test_sonny6704_single_hop_repeated_variable.zig; OWNER=engine; UPDATED=2026-11-17
/// SONNY-6705: the map `SET a = <rhs>` replaces a's properties with. A map is
/// itself; a node or relationship contributes its stored properties (the
/// openCypher `SET n = m` copy, read the way `properties(m)` reads them, so
/// the field-level-encryption read policy applies); any other value, NULL
/// included, is `TypeMismatch` (22G03). It used to clear every property of `a`
/// and report success for a rhs that was no map.
fn replacementMap(arena: std.mem.Allocator, rhs: Value) !Value {
    switch (rhs) {
        .Map => return rhs,
        .Node => |src| {
            var map = std.StringHashMap(Value).init(arena);
            var it = src.properties.iterator();
            while (it.next()) |entry| {
                const v: Value = if (entry.value_ptr.* == .String)
                    Value{ .Str = try fle_integration.readStoredStringForEntity(arena, .node, if (src.labels.len > 0) src.labels[0] else "Unknown", entry.key_ptr.*, entry.value_ptr.String, src.id, src.tenant_id) }
                else
                    try property_codec.propertyValueToProjectedValue(arena, entry.value_ptr.*);
                try map.put(entry.key_ptr.*, v);
            }
            return Value{ .Map = map };
        },
        .Edge => |src| {
            var map = std.StringHashMap(Value).init(arena);
            var it = src.properties.iterator();
            while (it.next()) |entry| {
                const v: Value = if (entry.value_ptr.* == .String)
                    Value{ .Str = try fle_integration.readStoredStringForEntity(arena, .edge, src.label, entry.key_ptr.*, entry.value_ptr.String, src.id, src.tenant_id) }
                else
                    try property_codec.propertyValueToProjectedValue(arena, entry.value_ptr.*);
                try map.put(entry.key_ptr.*, v);
            }
            return Value{ .Map = map };
        },
        else => return error.TypeMismatch,
    }
}

pub fn replaceNodeProperties(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    node: *graph_store.Node,
    rhs: Value,
) !void {
    // SONNY-6705: `SET a = a` keeps a as it is.
    if (rhs == .Node and rhs.Node.id == node.id) return;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const props_value = try replacementMap(arena_state.allocator(), rhs);
    // SONNY-6421: an indexed string the map drops or changes leaves its words
    // in the fulltext index (the clear below and the SETs after it see no old
    // value): queue its covering indexes for a rebuild at the statement's end.
    queueRebuildsForReplacedText(node, props_value);
    clearNodeProperties(store, node);

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

    for (node.labels) |label| rebuildAdvancedIndexesForLabel(store, label); // SONNY-6368: every label
}

fn queueRebuildsForReplacedText(node: *graph_store.Node, props_value: Value) void {
    var it = node.properties.iterator();
    while (it.next()) |entry| {
        const old = entry.value_ptr.*;
        if (old != .String or old.String.len == 0) continue;
        const key = entry.key_ptr.*;
        const new_value: ?Value = if (props_value == .Map) props_value.Map.get(key) else null;
        const kept = if (new_value) |v| switch (v) {
            .Str => |s| std.mem.eql(u8, s, old.String),
            else => false,
        } else false;
        if (!kept) fts_index_ops.queueRebuildForRemovedText(node.graph_name, node.labels, key);
    }
}

pub fn replaceEdgeProperties(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    edge: *graph_store.Edge,
    rhs: Value,
) !void {
    // SONNY-6705: `SET r = r` keeps r as it is.
    if (rhs == .Edge and rhs.Edge.id == edge.id) return;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const props_value = try replacementMap(arena_state.allocator(), rhs);
    clearEdgeProperties(store, edge);

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

// CANARY: REQ=REQ-SONNY-6368-REMOVE-MAINTENANCE; FEATURE="FullText"; ASPECT=RemoveProperty; STATUS=TESTED; TEST=tests/test_sonny6368_index_maintenance.zig; OWNER=engine; UPDATED=2026-11-12
/// REMOVE n.prop. SONNY-6368: the advanced indexes of every label of the
/// node (only the first label's were rebuilt), and the full-text indexes:
/// a removed non-empty string is text an index may hold, which the engine
/// cannot take out of one document, so every covering index is queued for a
/// rebuild at the end of the statement (`fts_index_ops.queueRebuildForRemovedText`).
/// The node stayed findable by the removed word.
pub fn removeNodeProperty(
    store: *graph_store.GraphStore,
    node: *graph_store.Node,
    key: []const u8,
) void {
    // SONNY-6612 (1): a value that cannot be read may be indexed text.
    const removed_text = if (store.getNodePropertyOrError(node.id, key)) |maybe| (if (maybe) |pv| pv == .String and pv.String.len > 0 else false) else |_| true;
    store.removeNodeProperty(node.id, key);
    for (node.labels) |label| rebuildAdvancedIndexesForProperty(store, label, key);
    if (removed_text) fts_index_ops.queueRebuildForRemovedText(node.graph_name, node.labels, key);
}

// CANARY: REQ=REQ-SONNY-6368-SET-LABEL-MAINTENANCE; FEATURE="Execution"; ASPECT=SetLabel; STATUS=TESTED; TEST=tests/test_sonny6368_index_maintenance.zig; OWNER=engine; UPDATED=2026-11-12
/// SET n:L. SONNY-6368: the node joins `label`, so it joins the full-text
/// and advanced (vector, ...) indexes on `label` with the properties it
/// already holds. The executors called `store.addNodeLabel` alone, so a
/// node given a label was found by neither search. The full-text document
/// is appended only if the index does not hold the node (`.create`).
pub fn addNodeLabel(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    node_id: u64,
    label: []const u8,
) !void {
    try store.addNodeLabel(node_id, label);
    maintainAdvancedIndexesForLabelAdded(store, label, node_id);
    fts_index_ops.maintainFulltextOnWrite(allocator, null, node_id, &.{label}, .create) catch |err| {
        log.warn("fts maintain (SET label) failed for node {d} label '{s}': {}", .{ node_id, label, err });
    };
}

// CANARY: REQ=REQ-SONNY-6421-REMOVE-LABEL-MAINTENANCE; FEATURE="Execution"; ASPECT=RemoveLabel; STATUS=TESTED; TEST=tests/test_sonny6421_index_maintenance.zig; OWNER=engine; UPDATED=2026-11-12
/// REMOVE n:L. SONNY-6421: the node leaves `label`, so it leaves the
/// full-text and advanced (vector, ...) indexes on `label`. The executors
/// called `store.removeNodeLabel` alone, so a full-text search still found
/// the node by L's index and the vector index still ranked it. The advanced
/// indexes on the label are rebuilt (queued to the statement's end like any
/// advanced rebuild; HNSW has no remove), and a full-text index holding text
/// of the node is queued for a rebuild at the statement's end
/// (`fts_index_ops.queueRebuildForRemovedLabel`).
pub fn removeNodeLabel(
    store: *graph_store.GraphStore,
    node_id: u64,
    label: []const u8,
) !void {
    const carried = if (store.getNodePtr(node_id)) |n| hasLabel(n.labels, label) else true;
    try store.removeNodeLabel(node_id, label);
    if (!carried) return;
    rebuildAdvancedIndexesForLabel(store, label);
    const graph_name = if (store.getNodePtr(node_id)) |n| n.graph_name else graph_store.DEFAULT_GRAPH_NAME;
    fts_index_ops.queueRebuildForRemovedLabel(store, graph_name, node_id, label);
}

fn hasLabel(labels: []const []const u8, label: []const u8) bool {
    for (labels) |l| if (std.mem.eql(u8, l, label)) return true;
    return false;
}

/// SONNY-6421: does writing `new` to `key` of `node_id` take indexed-able
/// text away (the old value a non-empty string the new one does not equal)?
fn replacesText(store: *graph_store.GraphStore, node_id: u64, key: []const u8, new: ?graph_store.PropertyValue) bool {
    // SONNY-6612 (1): an old value that cannot be read may be indexed text.
    const old = (store.getNodePropertyOrError(node_id, key) catch return true) orelse return false;
    if (old != .String or old.String.len == 0) return false;
    const n = new orelse return true;
    return n != .String or !std.mem.eql(u8, n.String, old.String);
}

/// The advanced indexes on `label` over a property the node holds: an
/// incremental insert, or a rebuild (`maintainAdvancedIndexesForNodeWrite`).
/// The indexed properties are copied under `rebuild_mutex`, which is
/// released before any insert or rebuild takes it.
fn maintainAdvancedIndexesForLabelAdded(store: *graph_store.GraphStore, label: []const u8, node_id: u64) void {
    const manager = index_manager.getGlobalIndexManager() orelse return;
    if (!manager.hasAdvancedIndexForLabel(label)) return;
    var properties: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (properties.items) |p| store.allocator.free(p);
        properties.deinit(store.allocator);
    }
    const copied = blk: {
        const io = std.Io.Threaded.global_single_threaded.io();
        manager.rebuild_mutex.lockUncancelable(io);
        defer manager.rebuild_mutex.unlock(io);
        var it = manager.advanced_property_indexes.iterator();
        while (it.next()) |entry| {
            const meta = entry.value_ptr.*;
            if (!std.mem.eql(u8, meta.label, label)) continue;
            const copy = store.allocator.dupe(u8, meta.property) catch break :blk false;
            properties.append(store.allocator, copy) catch {
                store.allocator.free(copy);
                break :blk false;
            };
        }
        break :blk true;
    };
    if (!copied) {
        // error-policy: B — out of memory: rebuild every index on the label
        // from the store instead (it queues, or runs, as any rebuild does).
        log.warn("advanced index maintenance for SET label '{s}': OutOfMemory; rebuilding its indexes", .{label});
        return rebuildAdvancedIndexesForLabel(store, label);
    }
    for (properties.items) |property| {
        // Borrowed: the statement's graph lock keeps it alive for the call.
        // SONNY-6612 (1): a value that cannot be read: rebuild the label's
        // indexes from the store instead of skipping the node.
        const prop = (store.getNodePropertyOrError(node_id, property) catch return rebuildAdvancedIndexesForLabel(store, label)) orelse continue;
        maintainAdvancedIndexesForNodeWrite(store, label, property, node_id, prop);
    }
}

pub fn removeEdgeProperty(
    store: *graph_store.GraphStore,
    edge: *graph_store.Edge,
    key: []const u8,
) void {
    store.removeEdgeProperty(edge.id, key);
    rebuildAdvancedIndexesForProperty(store, edge.label, key);
}
