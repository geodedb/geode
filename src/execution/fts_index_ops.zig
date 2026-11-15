// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// CANARY: REQ=REQ-GQL-FTS-DDL-001; FEATURE="Fulltext CREATE/DROP INDEX"; ASPECT=DDL; STATUS=TESTED; TEST=tests/test_fts_e2e.zig; OWNER=index; UPDATED=2026-05-30
//
//! A4a: DDL glue that wires `CREATE INDEX ... USING fulltext` / `DROP INDEX`
//! into the fts-storage adapter. Kept out of the giant `execution.zig` switch so
//! the FTS-specific imports (graph_store, tokenizer, fts adapter) stay localized.
//!
//! Responsibilities:
//!   * `createFulltextIndex` — create a NAMED adapter index for (label, props)
//!     on the current graph, then BACKFILL every existing node carrying `label`
//!     by tokenizing its indexed string properties and indexing them under the
//!     new engine. Honors IF NOT EXISTS. Flushes for durability + segment form.
//!   * `dropFulltextIndex` — drop the NAMED adapter index and free its cached
//!     facade. Honors IF EXISTS.
//!
//! The node create/update/delete write-maintenance hook is the NEXT task (A4b);
//! this file only handles DDL + one-shot backfill of pre-existing nodes.

const std = @import("std");
const graph_store = @import("../graph_store.zig");
const tokenizer = @import("../index/fts_tokenizer.zig");
const adapter_mod = @import("../storage/fts_storage_adapter.zig");
const graph_storage_adapter = @import("../storage/graph_storage_adapter.zig");
const catalog_mod = @import("../schema/catalog.zig");
const cluster_replication = @import("../distributed/cluster_replication.zig");
const raft_snapshot_manager = @import("../distributed/raft_snapshot_manager.zig");

const log = std.log.scoped(.fts_index_ops);

pub const Error = error{
    /// The fulltext index name already exists (and IF NOT EXISTS was absent).
    FulltextIndexExists,
    /// FTS is unavailable on the resolved graph (adapter not initialised).
    FulltextUnavailable,
    /// GAP-0922: every existing value of the indexed property is non-string
    /// (e.g. an INTEGER column). A fulltext index over it would be permanently
    /// dead — matching nothing — so DDL is rejected instead of silently
    /// building a useless index.
    FulltextRequiresTextProperty,
    /// Task 3 (geode-vectorization-and-reranking): `CALL geode.fts.rebuild`
    /// named an index unknown to both the schema catalog and the in-memory
    /// label registry.
    IndexNotFound,
};

/// Create a NAMED fulltext index on `graph_name` for label `label` over the
/// string-valued properties in `properties`, then backfill existing matching
/// nodes. `allocator` is a scratch allocator for the backfill document buffers.
///
/// IF NOT EXISTS: when `if_not_exists` is set, an already-present index is a
/// no-op success; otherwise it surfaces `Error.FulltextIndexExists`.
///
/// Backfill detail (per A0 decision 2): for each existing node of `label`, every
/// indexed property is tokenized with its property name as the `TermPosting.field`
/// tag and the per-property postings are concatenated into ONE document per node
/// (one `indexNode` call per node — a second call for the same doc_id would
/// append duplicate postings; fts-storage `indexDocument` is append-only). Nodes
/// missing the property, or whose property is non-string, are skipped for that
/// property. An empty graph is a clean no-op.
pub fn createFulltextIndex(
    allocator: std.mem.Allocator,
    graph_name: []const u8,
    index_name: []const u8,
    label: []const u8,
    properties: []const []const u8,
) !void {
    const adapter = graph_store.getGlobalAdapter() orelse return Error.FulltextUnavailable;

    // Resolve (creating/opening if needed) the ManagedGraph that owns the fts
    // adapter for this graph. CREATE INDEX may be the FIRST op on a graph (before
    // any node write registered it in `engines`), so use getOrCreateGraph — the
    // same path every write uses — instead of the find-only lookupManagedGraph,
    // which returned GraphNotFound and silently disabled the index.
    const mg = adapter.getOrCreateGraph(graph_name) catch return Error.FulltextUnavailable;
    const fa = mg.fts_adapter orelse return Error.FulltextUnavailable;

    // CANARY: REQ=REQ-GAP-0922-FTS-NUMERIC-PROPERTY-REJECT; FEATURE="FullText"; ASPECT=TextPropertyValidation; STATUS=TESTED; TEST=tests/test_gap0922_fts_numeric_property.zig; OWNER=fts; UPDATED=2026-07-10
    // GAP-0922: reject a fulltext index whose indexed property is exclusively
    // non-string across existing nodes (e.g. an INTEGER column). Such an index
    // was silently built and matched nothing forever, with no diagnostic. If
    // the label has no nodes yet (index-first), we cannot judge — allow it.
    try validateTextProperty(graph_name, label, properties);

    // Create the engine. Treat "already exists" per IF NOT EXISTS.
    fa.createIndex(index_name) catch |err| switch (err) {
        adapter_mod.Error.IndexExists => {
            // Idempotent create requested → done (do NOT re-backfill: re-indexing
            // would duplicate postings in the append-only engine).
            return;
        },
        else => return err,
    };
    // error-policy: A — best-effort cleanup of the half-created index on an
    // already-failing path; the backfill error below is what propagates.
    errdefer fa.dropIndex(index_name) catch {};

    // Task 4 (geode-vectorization-and-reranking): backfill now reports how
    // many nodes it actually indexed. `createFulltextIndex` still returns
    // `!void` and has no result surface for the count, so discard it —
    // behavior here is unchanged from before Task 4.
    _ = try backfillExistingNodes(allocator, graph_name, index_name, label, properties, fa, null);

    // A4b: record (label → this index) so the node write-maintenance hook can
    // find covering indexes on CREATE/SET/DELETE. Done AFTER backfill so the
    // initial one-shot index of pre-existing nodes is not double-counted by a
    // concurrent write hook (writes on this graph run on the same connection
    // thread, so there is no real race, but the ordering keeps the invariant
    // clear). Uses the adapter allocator so the registry's owned strings share
    // the ManagedGraph lifetime, mirroring `dropFulltextFacade`.
    try mg.addFtsLabelIndex(adapter.allocator, label, index_name, properties);

    // Durability + segment formation. The same-process search path sees memtable
    // writes without this, but a flush hardens the WAL into a segment.
    fa.flush(index_name) catch |err| {
        log.warn("fulltext backfill flush failed for '{s}': {}", .{ index_name, err });
    };
}

/// Copies of an index's label and properties into `label_out` / `props_out`,
/// owned by `allocator`. On an error nothing is left allocated.
fn dupeSpec(
    allocator: std.mem.Allocator,
    label: []const u8,
    properties: []const []const u8,
    label_out: *[]const u8,
    props_out: *[]const []const u8,
) !void {
    const owned_label = try allocator.dupe(u8, label);
    errdefer allocator.free(owned_label);
    const owned_props = try allocator.alloc([]const u8, properties.len);
    var filled: usize = 0;
    errdefer {
        for (owned_props[0..filled]) |p| allocator.free(p);
        allocator.free(owned_props);
    }
    for (properties, 0..) |p, i| {
        owned_props[i] = try allocator.dupe(u8, p);
        filled = i + 1;
    }
    label_out.* = owned_label;
    props_out.* = owned_props;
}

/// SONNY-6368 test instrumentation: called by `rebuildFulltextIndex` once its
/// backfill has read the store, while the index is still rebuilding (before
/// the drain). A test holds the rebuild there to land a write, or an undo,
/// in its window.
pub var rebuild_backfilled_hook: ?*const fn (index_name: []const u8) void = null;

/// Spec geode-vectorization-and-reranking: post-bulk-ingest invariant — rebuild
/// the fulltext engine for `index_name` from current store contents. Resolves
/// the (label, properties) spec from the schema catalog when available (works
/// after restart), falling back to the in-memory label registry. Drops the
/// engine (clearing append-only tombstones), recreates it, re-backfills, and
/// re-arms the label registry so live maintenance resumes.
/// CANARY: REQ=REQ-FTS-REBUILD-001; FEATURE="CALL geode.fts.rebuild"; ASPECT=RebuildBackfill; STATUS=TESTED; TEST=tests/test_fts_rebuild.zig; OWNER=index; UPDATED=2026-08-29
/// CANARY: REQ=REQ-FTS-REBUILD-COUNT-001; FEATURE="CALL geode.fts.rebuild"; ASPECT=NodesIndexedAccuracy; STATUS=TESTED; TEST=tests/test_fts_rebuild.zig; OWNER=index; UPDATED=2026-08-29
pub fn rebuildFulltextIndex(
    allocator: std.mem.Allocator,
    catalog: *catalog_mod.Catalog,
    graph_name: []const u8,
    index_name: []const u8,
) !u64 {
    const adapter = graph_store.getGlobalAdapter() orelse return Error.FulltextUnavailable;
    const mg = adapter.getOrCreateGraph(graph_name) catch return Error.FulltextUnavailable;
    const fa = mg.fts_adapter orelse return Error.FulltextUnavailable;

    // Resolve label + properties: catalog first (survives restart — the DDL
    // path always writes this row, see execution.zig:1671), registry fallback
    // for a defensive edge case (mid-transition state with no catalog row).
    // Both branches dupe with `allocator`, freed by `owns_fallback_strings`
    // below. SONNY-2795: the catalog branch borrowed the row's strings, which
    // a concurrent DROP INDEX frees; it now copies them under the catalog
    // lock.
    var label: []const u8 = undefined;
    var properties: []const []const u8 = undefined;
    var owns_fallback_strings = false;
    defer if (owns_fallback_strings) {
        allocator.free(label);
        for (properties) |p| allocator.free(p);
        allocator.free(properties);
    };

    resolve: {
        // Catalog first: use the SAME accessor shape statement_dispatcher.zig's
        // ensureAdvancedVectorIndexForProperty uses to iterate indexes — scan
        // for the row whose `.name` matches and whose `.index_type` is a
        // fulltext index (`table_name` = label, `columns` = properties).
        {
            const io = std.Io.Threaded.global_single_threaded.io();
            catalog.rwlock.lockSharedUncancelable(io);
            defer catalog.rwlock.unlockShared(io);
            var it = catalog.indexes.valueIterator();
            while (it.next()) |info| {
                if (!std.mem.eql(u8, info.name, index_name)) continue;
                if (!std.mem.startsWith(u8, info.index_type, "fulltext")) continue;
                try dupeSpec(allocator, info.table_name, info.columns, &label, &properties);
                owns_fallback_strings = true;
                break :resolve;
            }
        }

        // Registry fallback: scan every (label -> []FtsIndexSpec) list for a
        // spec named `index_name` (the registry is keyed by label, not name).
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const entries = try mg.snapshotFtsLabelIndex(arena.allocator());
        for (entries) |entry| {
            if (!std.mem.eql(u8, entry.name, index_name)) continue;
            try dupeSpec(allocator, entry.label, entry.properties, &label, &properties);
            owns_fallback_strings = true;
            break :resolve;
        }

        // Neither the catalog nor the registry knows this index.
        return Error.IndexNotFound;
    }

    // Task 3 (geode-vectorization-and-reranking): arm the rebuild-state
    // registry BEFORE dropIndex so concurrent writers
    // (`maintainFulltextOnWrite`, reached from executor writes AND the raft
    // apply-hook's second writer thread) observe the flag and queue their
    // node ids instead of racing the drop→create gap. Errors
    // `Error.RebuildInProgress` if this index is already mid-rebuild —
    // refused rather than letting two drop→create sequences race the same
    // on-disk tree.
    try fa.beginRebuild(index_name);
    var drained = false;
    // Error-path cleanup: if anything below fails before we reach the
    // successful `endRebuild` call, clear the flag so writers resume normal
    // indexing instead of queuing forever. Whatever got queued in the
    // meantime is simply dropped here — the index itself is in a
    // known-bad/partial state on this path already (the propagating error
    // is what the caller sees), and a subsequent `CALL geode.fts.rebuild`
    // (now unblocked) re-backfills from current store state regardless.
    defer if (!drained) {
        const leftover = fa.endRebuild(index_name, allocator) catch &[_]u64{};
        allocator.free(leftover);
    };

    const store = graph_store.getGlobalStore(graph_store.global_allocator());
    var created = false;
    errdefer if (created) fa.dropIndex(index_name) catch {};
    var snapshot: []u64 = &[_]u64{};
    defer allocator.free(snapshot);

    // CANARY: REQ=REQ-SONNY-6368-REBUILD-AGAIN; FEATURE="FullText"; ASPECT=RebuildPasses; STATUS=TESTED; TEST=tests/test_sonny6368_index_maintenance.zig; OWNER=fts; UPDATED=2026-11-12
    // SONNY-6368: one pass per iteration. An undo whose index repair found
    // this rebuild running asked it to run again
    // (`FtsStorageAdapter.requestRebuildAgain`): its backfill may have read
    // the value the undo took back, which no pending id carries (the undo
    // writes through the store only). Such a pass starts over from the store
    // with the window still armed; the last pass ends the rebuild
    // (`finishRebuildPass`). The repair used to be refused and dropped.
    const backfill_count: usize, const pending: []u64 = while (true) {
        fa.dropIndex(index_name) catch |err| switch (err) {
            adapter_mod.Error.IndexNotFound => {}, // engine absent (e.g. post-restart) — fine
            else => return err,
        };
        created = false;
        try fa.createIndex(index_name);
        created = true;

        // Snapshot the label's node ids EXACTLY ONCE per pass: this is both
        // backfill's input and the drain's exclusion set below (see
        // `backfillExistingNodes`' `node_ids_override` doc comment for why a
        // second independent read would corrupt that exclusion set).
        allocator.free(snapshot);
        snapshot = &[_]u64{};
        const raw_snapshot = store.getNodesByLabel(graph_name, label) orelse &[_]u64{};
        snapshot = try allocator.dupe(u64, raw_snapshot);

        const count = try backfillExistingNodes(allocator, graph_name, index_name, label, properties, fa, snapshot);
        if (rebuild_backfilled_hook) |hook| hook(index_name);

        // Clearing the rebuild flag (on the last pass) allows live writes to
        // resume while the drain below processes its snapshot. See the drain.
        const pass = try fa.finishRebuildPass(index_name, allocator);
        if (!pass.again) break .{ count, pass.pending };
        // The next pass's backfill reads every queued id's current state.
        allocator.free(pass.pending);
    };
    drained = true;
    defer allocator.free(pending);

    // Drain: reindex every write queued during the window whose id is NOT
    // already covered by the snapshot backfill above just processed.
    //
    // NEVER delete-then-reindex here — fts-storage tombstones are permanent
    // per doc_id (the engine is append-only + tombstone-based), so a stray
    // `deleteNode` call on a doc_id that was never actually written into
    // THIS fresh post-drop engine would be a meaningless no-op at best, and
    // on a doc_id backfill DID write would PERMANENTLY hide it — same
    // rationale as the SET-chokepoint comment on `maintainFulltextOnWrite`.
    // Plain `.create`-style `indexNodeDocument` is safe here specifically
    // BECAUSE this loop only ever fires for ids EXCLUDED from the snapshot —
    // ids backfill never wrote a first posting for in this fresh engine.
    //
    // A node IN the snapshot whose properties changed mid-backfill keeps
    // backfill's (possibly stale) read of them — that residual staleness is
    // the SAME documented invariant as elsewhere in this file: verify FTS
    // visibility with a canary query after a bulk/ingestion operation rather
    // than assuming instantaneous consistency mid-write.
    var snapshot_set: std.AutoHashMapUnmanaged(u64, void) = .{};
    defer snapshot_set.deinit(allocator);
    try snapshot_set.ensureTotalCapacity(allocator, @intCast(snapshot.len));
    for (snapshot) |nid| snapshot_set.putAssumeCapacity(nid, {});

    // The rebuild flag is clear: live writes resume while this drain
    // processes its snapshot. Both the drain and live create hooks append
    // only if the engine has not indexed the id, under the same writer lock,
    // so a delayed notification cannot double the document's postings.
    //
    // An in-snapshot delete still leaves a stale posting until a later
    // rebuild: the snapshot exclusion below skips that queued id. Search-hit
    // resolution drops ids absent from the live store, so the stale posting
    // is not returned to a caller. Mid-backfill updates retain the documented
    // snapshot-staleness behavior above.
    // Task 4 (geode-vectorization-and-reranking): count only drained ids that
    // were ACTUALLY indexed — `indexNodeDocument` returns `false` (not an
    // error) for a node whose id vanished by drain time or that carried no
    // indexable text, mirroring exactly what `backfillExistingNodes` counts.
    var drain_count: usize = 0;
    for (pending) |nid| {
        if (snapshot_set.contains(nid)) continue; // backfill already indexed current state
        const indexed = indexNodeDocument(allocator, store, fa, index_name, nid, properties, true) catch |err| blk: {
            log.warn("rebuild drain reindex failed for node {}: {}", .{ nid, err });
            break :blk false;
        };
        if (indexed) drain_count += 1;
    }

    try mg.addFtsLabelIndex(adapter.allocator, label, index_name, properties); // idempotent re-arm
    fa.flush(index_name) catch |err| {
        log.warn("fulltext rebuild flush failed for '{s}': {}", .{ index_name, err });
    };

    return @intCast(backfill_count + drain_count);
}

// CANARY: REQ=REQ-SONNY-6368-REBUILD-AGAIN; FEATURE="FullText"; ASPECT=RebuildOrRequestAgain; STATUS=TESTED; TEST=tests/test_sonny6368_index_maintenance.zig; OWNER=fts; UPDATED=2026-11-12
/// SONNY-6368: bring `index_name` up to the store after a change its live
/// maintenance cannot express (an undo, a removed property): rebuild it, or,
/// when a rebuild of it is already running, have that rebuild run again from
/// the store once its pass is done (`FtsStorageAdapter.requestRebuildAgain`)
/// rather than drop the repair. Returns once one of the two is certain.
pub fn rebuildOrRequestAgain(
    allocator: std.mem.Allocator,
    catalog: *catalog_mod.Catalog,
    graph_name: []const u8,
    index_name: []const u8,
) !void {
    // A running rebuild that ends between our refusal and our request is
    // rebuilt by us on the next attempt; the bound only stops a pathological
    // stream of short rebuilds from holding the caller.
    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        _ = rebuildFulltextIndex(allocator, catalog, graph_name, index_name) catch |err| switch (err) {
            adapter_mod.Error.RebuildInProgress => {
                const adapter = graph_store.getGlobalAdapter() orelse return Error.FulltextUnavailable;
                const mg = adapter.lookupManagedGraph(graph_name) catch return Error.FulltextUnavailable;
                const fa = mg.fts_adapter orelse return Error.FulltextUnavailable;
                if (try fa.requestRebuildAgain(index_name)) return;
                continue;
            },
            else => return err,
        };
        return;
    }
    return adapter_mod.Error.RebuildInProgress;
}

// CANARY: REQ=REQ-SONNY-6368-REMOVE-MAINTENANCE; FEATURE="FullText"; ASPECT=RemovedTextRebuildQueue; STATUS=TESTED; TEST=tests/test_sonny6368_index_maintenance.zig; OWNER=fts; UPDATED=2026-11-12
/// SONNY-6368: the full-text indexes whose node lost indexed text (a
/// committed `REMOVE n.prop`) and so must be rebuilt: the engine cannot take
/// one property's postings out of a document (append-only; a tombstone hides
/// the node for good, and a later SET could not bring it back). A REMOVE
/// queues the index (`queueRebuildForRemovedText`); the statement's end
/// rebuilds each queued index once (`flushQueuedRebuilds`), so `MATCH (d:Doc)
/// REMOVE d.body` costs one O(nodes of the label) rebuild, not one per row.
/// Whoever ends a statement first takes the queue: every entry is rebuilt
/// after the REMOVE that queued it. `queue_mutex` is a leaf lock: held only
/// to add or take entries, never across a rebuild.
const QueuedRebuild = struct { graph: []u8, index: []u8 };
const queue_allocator = std.heap.smp_allocator;
var queue_mutex: std.Io.Mutex = .init;
var queued_rebuilds: std.ArrayListUnmanaged(QueuedRebuild) = .empty;
var queued_count: std.atomic.Value(usize) = .init(0);

/// SONNY-6368: node of `labels` in `graph_name` lost its text in `property`
/// (the caller saw a non-empty string there): queue every full-text index
/// covering one of the labels over that property for a rebuild at the end
/// of the statement. Never fails the write; an index that cannot be queued
/// is logged (it keeps answering for the removed text until rebuilt).
pub fn queueRebuildForRemovedText(graph_name: []const u8, labels: []const []const u8, property: []const u8) void {
    const adapter = graph_store.getGlobalAdapter() orelse return;
    const mg = adapter.lookupManagedGraph(graph_name) catch return;
    const fa = mg.fts_adapter orelse return;
    armLabelRegistry(adapter, mg, fa, graph_name); // SONNY-6591
    for (labels) |label| {
        const specs = mg.coveringFtsIndexes(label) orelse continue;
        for (specs) |spec| {
            for (spec.properties) |p| {
                if (!std.mem.eql(u8, p, property)) continue;
                queueRebuild(graph_name, spec.name) catch |err| {
                    log.err("fulltext index '{s}' could not be queued for a rebuild after a REMOVE: {}; it answers for the removed text until rebuilt", .{ spec.name, err });
                };
                break;
            }
        }
    }
}

// CANARY: REQ=REQ-SONNY-6421-REMOVE-LABEL-MAINTENANCE; FEATURE="FullText"; ASPECT=RemovedLabelRebuildQueue; STATUS=TESTED; TEST=tests/test_sonny6421_index_maintenance.zig; OWNER=fts; UPDATED=2026-11-12
/// SONNY-6421: node `node_id` of `graph_name` left `label` (REMOVE n:L):
/// queue every full-text index on `label` that holds text of the node (a
/// non-empty string in one of its properties) for a rebuild at the end of
/// the statement, as `queueRebuildForRemovedText` does for a removed
/// property. Call it after the label is removed: the properties stay. Never
/// fails the write.
pub fn queueRebuildForRemovedLabel(store: *graph_store.GraphStore, graph_name: []const u8, node_id: u64, label: []const u8) void {
    const adapter = graph_store.getGlobalAdapter() orelse return;
    const mg = adapter.lookupManagedGraph(graph_name) catch return;
    const fa = mg.fts_adapter orelse return;
    armLabelRegistry(adapter, mg, fa, graph_name); // SONNY-6591
    const specs = mg.coveringFtsIndexes(label) orelse return;
    for (specs) |spec| {
        for (spec.properties) |p| {
            const pv = store.getNodeProperty(node_id, p) orelse continue;
            if (pv != .String or pv.String.len == 0) continue;
            queueRebuild(graph_name, spec.name) catch |err| {
                log.err("fulltext index '{s}' could not be queued for a rebuild after a REMOVE of its label: {}; it holds the node's text until rebuilt (searches skip the node)", .{ spec.name, err });
            };
            break;
        }
    }
}

fn queueRebuild(graph_name: []const u8, index_name: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    queue_mutex.lockUncancelable(io);
    defer queue_mutex.unlock(io);
    for (queued_rebuilds.items) |q| {
        if (std.mem.eql(u8, q.graph, graph_name) and std.mem.eql(u8, q.index, index_name)) return;
    }
    const g = try queue_allocator.dupe(u8, graph_name);
    errdefer queue_allocator.free(g);
    const i = try queue_allocator.dupe(u8, index_name);
    errdefer queue_allocator.free(i);
    try queued_rebuilds.append(queue_allocator, .{ .graph = g, .index = i });
    _ = queued_count.fetchAdd(1, .release);
}

/// SONNY-6368: rebuild every queued index (`queueRebuildForRemovedText`).
/// Called at the end of each outermost statement (`execution`), still under
/// the graph lock it holds; a rebuild takes no graph lock. A rebuild already
/// running for an index runs again instead (`rebuildOrRequestAgain`).
pub fn flushQueuedRebuilds(catalog: *catalog_mod.Catalog) void {
    if (queued_count.load(.acquire) == 0) return;
    var taken: std.ArrayListUnmanaged(QueuedRebuild) = .empty;
    {
        const io = std.Io.Threaded.global_single_threaded.io();
        queue_mutex.lockUncancelable(io);
        defer queue_mutex.unlock(io);
        taken = queued_rebuilds;
        queued_rebuilds = .empty;
        queued_count.store(0, .release);
    }
    defer {
        for (taken.items) |q| {
            queue_allocator.free(q.graph);
            queue_allocator.free(q.index);
        }
        taken.deinit(queue_allocator);
    }
    var arena = std.heap.ArenaAllocator.init(queue_allocator);
    defer arena.deinit();
    for (taken.items) |q| {
        rebuildOrRequestAgain(arena.allocator(), catalog, q.graph, q.index) catch |err| switch (err) {
            // Dropped since it was queued: nothing left to answer for.
            Error.IndexNotFound => {},
            else => log.err("fulltext index '{s}' could not be rebuilt after a REMOVE: {}; it answers for the removed text until rebuilt", .{ q.index, err }),
        };
    }
}

/// GAP-0922: scan existing nodes of `label` and reject the fulltext index if
/// every present value of every indexed property is non-string. Returns
/// cleanly (allowing the index) when the label has no nodes, or when at least
/// one indexed property holds at least one string value on some node.
pub fn validateTextProperty(
    graph_name: []const u8,
    label: []const u8,
    properties: []const []const u8,
) Error!void {
    const store = graph_store.getGlobalStore(graph_store.global_allocator());
    const node_ids = store.getNodesByLabel(graph_name, label) orelse return; // no nodes → allow
    if (node_ids.len == 0) return;

    var saw_any_value = false;
    for (node_ids) |node_id| {
        for (properties) |prop| {
            const pv = store.getNodeProperty(node_id, prop) orelse continue;
            switch (pv) {
                .String => return, // at least one string value → text index is meaningful
                .Null => {},
                else => saw_any_value = true, // a present non-string value
            }
        }
    }
    // Every present value across all indexed properties was non-string.
    if (saw_any_value) return Error.FulltextRequiresTextProperty;
}

/// Backfill loop, factored out so the create path stays readable.
///
/// `node_ids_override`: when non-null, backfill THESE ids instead of doing
/// its own `store.getNodesByLabel` read. Task 3 (geode-vectorization-and-
/// reranking) uses this from `rebuildFulltextIndex`, which must snapshot the
/// label's node ids EXACTLY ONCE — that single read is both backfill's input
/// AND the post-backfill drain's exclusion set. A second independent read
/// here (this function doing its own `getNodesByLabel` call) could observe a
/// DIFFERENT (longer) id list than the caller's snapshot if a write raced in
/// between the two reads, corrupting the drain's "already covered by
/// backfill" check. `createFulltextIndex` and `rebuildAllFulltextIndexes`
/// pass `null` (unchanged behavior — no drain phase follows their backfill).
///
/// Returns the count of nodes actually submitted to `fa.indexNode`
/// SUCCESSFULLY — nodes carrying `label` are NOT all counted; a node with no
/// indexed property present, an empty string, or every indexed property
/// non-string produces an empty `doc_terms` and is skipped (not counted), and
/// a node whose `fa.indexNode` call itself errors is logged and not counted
/// either (Task 4, geode-vectorization-and-reranking: previously callers
/// reported `store.getNodesByLabel(...).len`, which over-counted by including
/// exactly these skipped nodes).
fn backfillExistingNodes(
    allocator: std.mem.Allocator,
    graph_name: []const u8,
    index_name: []const u8,
    label: []const u8,
    properties: []const []const u8,
    fa: *adapter_mod.FtsStorageAdapter,
    node_ids_override: ?[]const u64,
) !usize {
    const store = graph_store.getGlobalStore(graph_store.global_allocator());

    // Borrowed posting list of node ids for this (graph, label); null = no nodes.
    const raw_node_ids = node_ids_override orelse (store.getNodesByLabel(graph_name, label) orelse return 0);

    // Sort ids ASCENDING before indexing (on an owned copy — the store slice is
    // borrowed). The adapter's segment-order guard force-flushes the memtable
    // whenever an id lands below the running max, so a mixed-band id sequence
    // (GNC2 raft-derived ~2^40 interleaved with time-based ~2^57) would
    // otherwise trigger a flush-per-inversion storm of tiny segments. Sorted
    // input means at most the one initial flush.
    const node_ids = try allocator.dupe(u64, raw_node_ids);
    defer allocator.free(node_ids);
    std.mem.sort(u64, node_ids, {}, std.sort.asc(u64));

    var indexed_count: usize = 0;
    for (node_ids) |node_id| {
        // Build ONE document per node from the field-tagged postings of every
        // indexed property. Accumulate into a single buffer so we issue a single
        // indexNode call (append-only engine → no per-property calls).
        //
        // Ownership: each posting's `term`/`positions` were allocated by
        // `tokenize`. We MOVE the elements out of the tokenize slice into
        // `doc_terms`, free the tokenize slice header, and free each element's
        // term/positions individually in the defer. We must NOT use
        // `freeTermPostings(doc_terms.items)` because that ALSO frees the slice
        // and would double-free against `doc_terms.deinit`.
        var doc_terms: std.ArrayListUnmanaged(tokenizer.TermPosting) = .empty;
        defer {
            for (doc_terms.items) |p| {
                allocator.free(p.term);
                allocator.free(p.positions);
                if (p.field) |f| allocator.free(f);
            }
            doc_terms.deinit(allocator);
        }

        for (properties) |prop| {
            const pv = store.getNodeProperty(node_id, prop) orelse continue;
            const text = switch (pv) {
                .String => |s| s,
                else => continue, // only string is indexable for FTS (skip Int/Float/Bool/Null/...)
            };
            if (text.len == 0) continue;

            // Tokenize with the property name as the field tag so multi-property
            // indexes can be searched per-field later.
            const postings = tokenizer.tokenize(allocator, text, prop) catch |err| {
                log.warn("fulltext backfill tokenize failed (node {d}, prop '{s}'): {}", .{ node_id, prop, err });
                continue;
            };
            // Empty result (all stopwords / no tokens): tokenize returns the
            // static empty slice — nothing to move, and freeing a zero-length
            // slice is a no-op, but skip to keep the move/free path uniform.
            if (postings.len == 0) continue;
            // Move each posting element into doc_terms, then free only the
            // tokenize slice header (its elements are now owned by doc_terms).
            doc_terms.appendSlice(allocator, postings) catch |err| {
                tokenizer.freeTermPostings(allocator, postings);
                return err;
            };
            allocator.free(postings);
        }

        if (doc_terms.items.len == 0) continue; // nothing indexable on this node

        if (fa.indexNodeIfAbsent(index_name, node_id, doc_terms.items)) |indexed| {
            if (indexed) indexed_count += 1;
        } else |err| {
            log.warn("fulltext backfill indexNode failed (node {d}): {}", .{ node_id, err });
        }
    }

    return indexed_count;
}

/// Drop the NAMED fulltext index `index_name` on `graph_name`: tear down the
/// adapter engine (flush + deinit + on-disk delete) and free the cached facade.
///
/// IF EXISTS: when `if_exists` is set, a missing index is a no-op success;
/// otherwise a missing index surfaces `adapter_mod.Error.IndexNotFound`. When
/// FTS is unavailable on the graph, treats as nothing-to-drop (no-op) so DROP
/// INDEX of a fulltext index never spuriously fails on a graph without FTS.
pub fn dropFulltextIndex(
    graph_name: []const u8,
    index_name: []const u8,
    if_exists: bool,
) !void {
    const adapter = graph_store.getGlobalAdapter() orelse {
        if (if_exists) return;
        return adapter_mod.Error.IndexNotFound;
    };
    const mg = adapter.lookupManagedGraph(graph_name) catch {
        if (if_exists) return;
        return adapter_mod.Error.IndexNotFound;
    };
    const fa = mg.fts_adapter orelse {
        if (if_exists) return;
        return adapter_mod.Error.IndexNotFound;
    };

    // Free the cached facade first (it borrows the engine we are about to drop).
    mg.dropFulltextFacade(adapter.allocator, index_name);

    // A4b: drop the label→index registry entries for this index so the write
    // hook stops maintaining it. Scans all label lists by name (drop is keyed by
    // index name only — no label parameter is available here).
    mg.removeFtsLabelIndex(adapter.allocator, index_name);

    fa.dropIndex(index_name) catch |err| switch (err) {
        adapter_mod.Error.IndexNotFound => {
            if (!if_exists) return err;
        },
        else => return err,
    };
}

/// A4b: the kind of node write that triggered maintenance.
pub const FtsWriteOp = enum { create, upsert, update, delete };

// CANARY: REQ=REQ-SONNY-6591-FTS-REGISTRY-AFTER-RESTART; FEATURE="FullText"; ASPECT=RegistryArmedFromCatalog; STATUS=TESTED; TEST=tests/test_sonny6591_fts_write_paths.zig; OWNER=fts; UPDATED=2026-11-15
/// SONNY-6591: fill `mg`'s label -> fulltext index registry from the catalog
/// and open each index's engine, once per opened graph.
///
/// The registry every maintenance hook reads (`coveringFtsIndexes`) lives in
/// memory and was filled only by CREATE INDEX and `rebuildFulltextIndex`. A
/// restart left it empty while the catalog still recorded the index and its
/// engine re-opened on the first search, so after a restart no write reached
/// the index: CREATE, SET and MERGE indexed nothing, DELETE left the node's
/// postings, and REMOVE queued no rebuild. The catalog row (written by every
/// CREATE INDEX, removed by DROP INDEX) is the durable record; the hooks call
/// this first, so the first write after a restart finds the index.
///
/// One atomic load once armed. Until the catalog exists, or while an engine
/// that is on disk cannot be opened, the graph stays unarmed and the next
/// hook tries again. A catalog row whose engine is not on this graph (no
/// directory: `IndexNotFound`, e.g. mid-rebuild, which re-arms the index
/// itself) is skipped. The catalog lock is held only to copy the rows; no
/// graph lock is taken (callers may hold one: graph locks are below the
/// catalog in the lock order).
fn armLabelRegistry(
    adapter: *graph_storage_adapter.StorageAdapter,
    mg: *graph_storage_adapter.ManagedGraph,
    fa: *adapter_mod.FtsStorageAdapter,
    graph_name: []const u8,
) void {
    if (mg.fts_registry_armed.load(.acquire)) return;
    const execution = @import("../execution.zig");
    const catalog = if (execution.getActiveContext()) |ctx| ctx.catalog else (execution.getCatalogInstanceIfPresent() orelse return);

    var arena = std.heap.ArenaAllocator.init(adapter.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Row = struct { name: []const u8, label: []const u8, properties: []const []const u8 };
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    {
        const io = std.Io.Threaded.global_single_threaded.io();
        catalog.rwlock.lockSharedUncancelable(io);
        defer catalog.rwlock.unlockShared(io);
        var it = catalog.indexes.valueIterator();
        while (it.next()) |info| {
            if (!std.mem.startsWith(u8, info.index_type, "fulltext")) continue;
            if (!catalog_mod.rowInGraph(info.graph, graph_name)) continue;
            var row: Row = .{ .name = undefined, .label = undefined, .properties = undefined };
            dupeSpec(a, info.table_name, info.columns, &row.label, &row.properties) catch return;
            row.name = a.dupe(u8, info.name) catch return;
            rows.append(a, row) catch return;
        }
    }

    var complete = true;
    for (rows.items) |row| {
        if (fa.getIndex(row.name) == null) {
            fa.openIndex(row.name) catch |err| switch (err) {
                adapter_mod.Error.IndexNotFound => continue,
                adapter_mod.Error.IndexExists => {}, // opened by a concurrent search
                else => {
                    log.warn("fulltext index '{s}' could not be opened for write maintenance: {}; writes do not reach it until it opens", .{ row.name, err });
                    complete = false;
                    continue;
                },
            };
        }
        mg.addFtsLabelIndex(adapter.allocator, row.label, row.name, row.properties) catch |err| {
            log.warn("fulltext index '{s}' could not be registered for write maintenance: {}", .{ row.name, err });
            complete = false;
        };
    }
    if (complete) mg.fts_registry_armed.store(true, .release);
}

/// A4b: keep fulltext indexes current after a single-node write. CHEAP-EXITS
/// when no fulltext index covers any of `labels` (the dominant case → near-zero
/// overhead for non-FTS graphs).
///
/// THREAD-SAFETY (A4b §6): MUST be called on the executor/connection thread —
/// the SAME thread that ran `CREATE INDEX` and therefore owns the fts engine.
/// The fts engine enforces a single-writer owning-thread contract; callers on
/// worker threads (e.g. the bulk MERGE fast path `bulkMergeNode`) MUST NOT call
/// this — they reindex post-bulk on the connection thread instead.
///
/// Behavior per covering index (de-duplicated by index name across labels):
///   * `.delete` / `.update`: `deleteNode(name, node_id)` to drop stale postings
///     (the engine is append-only — re-indexing without deleting duplicates).
///   * `.create`: index the document only if its id has not been indexed.
///   * `.upsert` / re-index tail of `.update`: read each `spec.properties` from
///     the store (`.String` only), tokenize with the property name as the field
///     tag, concatenate into ONE document, and `indexNode(name, node_id, doc)`.
///
/// Errors: a missing index (`IndexNotFound`) on EITHER leg — delete or
/// create/update — is tolerated (logged at debug). The create/update leg's
/// tolerance closes review Finding 1 (2026-08-29 rebuild-race hardening
/// round): `noteWriteDuringRebuild`'s pre-check has a documented TOCTOU
/// window against `beginRebuild`+`dropIndex` (see fts_storage_adapter.zig's
/// `rebuilds` field doc), so a write can pass the pre-check and still find
/// the engine gone by the time `indexNode` runs — an expected under-rebuild
/// condition the feature absorbs via the rebuild's post-backfill drain, not a
/// real failure. Other engine errors are SURFACED so a failing index on a
/// committed user write is visible rather than silently dropped.
pub fn maintainFulltextOnWrite(
    scratch: std.mem.Allocator,
    graph_name: ?[]const u8,
    node_id: u64,
    labels: []const []const u8,
    op: FtsWriteOp,
) !void {
    // Fast cheap-exit: no adapter at all (FTS subsystem absent) → nothing to do.
    const adapter = graph_store.getGlobalAdapter() orelse return;
    const store = graph_store.getGlobalStore(graph_store.global_allocator());

    // Resolve the owning graph. CREATE/DELETE pass `target_graph` directly; the
    // SET chokepoint has no graph in scope, so it passes null and we read the
    // node's `graph_name` tag from the store by id (the node still exists at
    // create/update time). Fall back to the default graph if the node is gone.
    // A missing graph is a clean no-op — never fail a user write for missing FTS.
    const gname = graph_name orelse blk: {
        const np = store.getNodePtr(node_id) orelse break :blk graph_store.DEFAULT_GRAPH_NAME;
        break :blk np.graph_name;
    };

    const mg = adapter.lookupManagedGraph(gname) catch return;
    const fa = mg.fts_adapter orelse return; // no FTS on this graph → free exit
    armLabelRegistry(adapter, mg, fa, gname); // SONNY-6591: one atomic load once armed

    // De-dup index names across labels so a node carrying two labels both
    // covered by the same index is maintained exactly once (otherwise `.create`
    // would double-append the same document into the append-only engine).
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(scratch);

    for (labels) |label| {
        const specs = mg.coveringFtsIndexes(label) orelse continue;
        for (specs) |spec| {
            const gop = try seen.getOrPut(scratch, spec.name);
            if (gop.found_existing) continue;

            // Task 3 (geode-vectorization-and-reranking): `CALL
            // geode.fts.rebuild`'s drop→create→backfill window. If
            // `spec.name` is currently rebuilding, queue this node id
            // instead of touching the engine at all — for BOTH legs below.
            // There may be NO engine right now (mid drop→create), and even
            // once a fresh one exists, a write landing here ahead of
            // backfill's snapshot read would get double-indexed once
            // backfill (also) picks the node up. The rebuild's post-backfill
            // drain reindexes every queued id NOT already covered by its
            // backfill snapshot, reading current store state — so a delete
            // arriving here for an id that ends up pending is handled
            // correctly too, with no special casing needed: the drain's
            // write naturally no-ops for a node that no longer exists (see
            // fts_storage_adapter.zig's `rebuilds` field doc for the full
            // model, including a documented narrow-race residual this
            // pre-check alone does not fully close).
            if (fa.noteWriteDuringRebuild(spec.name, node_id)) continue;

            // Drop stale postings for update/delete. Tolerate a missing engine
            // (IndexNotFound) — e.g. a first-ever SET on a never-indexed node,
            // or the same rebuild TOCTOU window documented on the create/update
            // leg below.
            if (op == .delete or op == .update) {
                fa.deleteNode(spec.name, node_id) catch |err| switch (err) {
                    adapter_mod.Error.IndexNotFound => log.debug("fulltext maintain delete: index '{s}' not found for node {d} (rebuild race or never-indexed) — skipping", .{ spec.name, node_id }),
                    else => return err,
                };
            }

            if (op == .create or op == .upsert or op == .update) {
                // Tolerate a missing engine (IndexNotFound) here too: the
                // `noteWriteDuringRebuild` pre-check above has a documented
                // TOCTOU window against `beginRebuild`+`dropIndex` (see
                // fts_storage_adapter.zig's `rebuilds` field doc) — this
                // write can pass the pre-check and then find the engine gone
                // by the time `indexNode` runs. That is the expected
                // under-rebuild condition the feature absorbs (the node was
                // already queued or will be picked up by the rebuild's
                // post-backfill drain), not a real failure. Mirror the
                // delete leg above; only IndexNotFound is swallowed, every
                // other error still propagates. The returned bool (whether it
                // actually indexed) is not needed here — this is a per-write
                // maintenance hook, not a bulk count — so discard it.
                _ = indexNodeDocument(scratch, store, fa, spec.name, node_id, spec.properties, op == .create) catch |err| switch (err) {
                    adapter_mod.Error.IndexNotFound => blk: {
                        log.debug("fulltext maintain create/update: index '{s}' not found for node {d} (rebuild race) — skipping, drain will reindex", .{ spec.name, node_id });
                        break :blk false;
                    },
                    else => return err,
                };
            }
        }
    }
}

/// A4b: rebuild ONE fulltext document for `node_id` from `properties` and index
/// it under `index_name`. Mirrors `backfillExistingNodes`' tokenize + move/free
/// ownership contract EXACTLY (see §1.3 of the change-map): postings from
/// `tokenize` are MOVED into the accumulator, the tokenize slice header is freed,
/// and each accumulated element's `term`/`positions` are freed in the defer — we
/// MUST NOT call `freeTermPostings` on the accumulator (double-free vs deinit).
///
/// CANARY: REQ=REQ-ENG-3954-FTS-MAINTAIN-UAF; FEATURE="FTS live-maintenance property read"; ASPECT=ShardLockedCopy; STATUS=TESTED; TEST=tests/test_fts_bulk_merge_maintenance.zig|tests/test_scan_ingest_race.zig|tests/test_bulk_shard_concurrency.zig|tests/test_fts_e2e.zig; OWNER=index; UPDATED=2026-08-28
/// Whole-branch review Finding 2 (UAF class, ENG-3954 family): every
/// property's raw text is copied out from under the shard's SHARED lock
/// BEFORE tokenizing, instead of reading through `store.getNodeProperty`
/// unlocked. `store.getNodeProperty`'s returned `String` BORROWS the node's
/// live property storage and is only valid while a lock excludes a
/// concurrent SET/DELETE for the read's duration (see its doc comment in
/// graph_store.zig). The bulk-MERGE fast path's live-maintenance call sites
/// (quic_connection_handler.zig `executeBulkSimpleMerge` /
/// `executeBulkMergeBatch`) run on the correct fts-engine-owning thread but
/// call `maintainFulltextOnWrite` AFTER releasing the graph lock, so a
/// concurrent SET/DELETE from ANOTHER connection racing the same node could
/// realloc/free the property mid-read.
///
/// Uses the SAME `lockShardShared` + `getPtrUnlocked` pattern as
/// `fts_dispatch.filterAuthorizedHits` / `eval.scanVectorKnn` (ENG-3954 /
/// #874) — deliberately NOT `store.getNodeProperty`, which internally
/// re-acquires the same shard's map_lock and would nest a second shared
/// acquisition on top of the one already held here (`node_cache.zig`'s
/// `lockShardShared` doc: "no re-entrant cache calls while held"). No other
/// existing `maintainFulltextOnWrite` caller (CREATE batch fast path, the SET
/// chokepoint, DELETE, raft-apply/snapshot-install) holds this shard lock at
/// its call site either, so adding it here is safe for all of them — no
/// double-lock, no ordering change against the tier-1 table in CLAUDE.md.
///
/// Task 5 (geode-vectorization-and-reranking, 2026-08-29): when the shard
/// lock's `getPtrUnlocked` misses (the node was evicted from the bounded
/// cache before this hook ran, though still durable), fall back — OUTSIDE
/// the shard lock — to `store.getNodePropertyValue`'s hydrate-on-miss path.
/// That accessor is self-locking (`getOrHydratePtr`) and, like the resident
/// fast path above, does NOT decrypt FLE — the same ciphertext-indexing
/// posture is preserved on both paths. `error.NodeNotFound` there maps to
/// the same "vanished, no fallback possible" `false` return as the old
/// resident-only miss.
///
/// Residual: this bypasses FLE decryption (`store.getNodeProperty` decrypts
/// FLE-encrypted fields; the raw shard-locked copy here does not — RBAC/FLE
/// role state is request-scoped and unsafe to read this late in a
/// write-committed maintenance hook, and FLE+FTS indexing has no existing
/// test coverage). When no FLE fields are configured
/// (`fle_integration.hasEncryptedFields() == false`, the default/tested
/// posture) behavior is byte-for-byte identical to before this fix. When FLE
/// IS configured, an indexed FLE field now stores its ciphertext envelope
/// rather than decrypted plaintext — narrower exposure than before, not
/// wider, and a pre-existing FLE+FTS interaction gap this fix does not
/// newly introduce.
///
/// Returns `true` when `node_id` was ACTUALLY submitted to `fa.indexNode`
/// (mirrors `backfillExistingNodes`' counting rule — Task 4,
/// geode-vectorization-and-reranking); `false` when the node had already
/// vanished by the time this ran, carried no indexable text, or an if-absent
/// create found the document already indexed. Callers that need a drain/backfill-style
/// count (`rebuildFulltextIndex`) use this; `maintainFulltextOnWrite` (a
/// per-write hook, not a bulk count) discards it.
fn indexNodeDocument(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    fa: *adapter_mod.FtsStorageAdapter,
    index_name: []const u8,
    node_id: u64,
    properties: []const []const u8,
    if_absent: bool,
) !bool {
    var doc_terms: std.ArrayListUnmanaged(tokenizer.TermPosting) = .empty;
    defer {
        for (doc_terms.items) |p| {
            allocator.free(p.term);
            allocator.free(p.positions);
            if (p.field) |f| allocator.free(f);
        }
        doc_terms.deinit(allocator);
    }

    const RawProp = struct { key: []const u8, text: []u8 };
    var raw_props: std.ArrayListUnmanaged(RawProp) = .empty;
    defer {
        for (raw_props.items) |rp| allocator.free(rp.text);
        raw_props.deinit(allocator);
    }
    var resident = false;
    {
        // Everything that touches the node's interior stays inside this
        // guard: the copy (allocator.dupe) must complete before the shard
        // lock drops, or the source bytes it reads from could already be
        // gone.
        store.nodes.lockShardShared(node_id);
        defer store.nodes.unlockShardShared(node_id);
        if (store.nodes.getPtrUnlocked(node_id)) |np| {
            resident = true;
            for (properties) |prop| {
                const pv = np.properties.get(prop) orelse continue;
                const text = switch (pv) {
                    .String => |s| s,
                    else => continue, // only string is indexable for FTS
                };
                if (text.len == 0) continue;
                try raw_props.append(allocator, .{ .key = prop, .text = try allocator.dupe(u8, text) });
            }
        }
    }

    // Fast path: resident node — copy property text under the shard's
    // SHARED lock (realloc-safe). Fallback: hydrate-on-miss via
    // getNodePropertyValue (self-locking, NO FLE decrypt — ciphertext
    // indexing posture preserved), for nodes evicted from the bounded
    // cache between write-commit and this hook.
    // CANARY: REQ=REQ-FTS-MAINT-HYDRATE-001; FEATURE="FullText"; ASPECT=NonResidentFallback; STATUS=TESTED; TEST=tests/test_fts_bulk_merge_maintenance.zig; OWNER=fts; UPDATED=2026-08-29
    if (!resident) {
        // Never call the hydrating accessor while the shard lock is held —
        // it is self-locking (getOrHydratePtr) and re-entrant cache calls
        // are forbidden (node_cache.zig's lockShardShared contract). We are
        // outside that lock here.
        for (properties) |prop| {
            const pv = store.getNodePropertyValue(node_id, prop) catch |err| switch (err) {
                error.NodeNotFound => return false, // genuinely gone — no fallback possible
                error.PropertyNotFound => continue,
                else => return err,
            };
            const text = switch (pv) {
                .String => |s| s,
                else => continue, // only string is indexable for FTS
            };
            if (text.len == 0) continue;
            try raw_props.append(allocator, .{ .key = prop, .text = try allocator.dupe(u8, text) });
        }
    }

    // Tokenizing, appending to doc_terms, and calling into the fts engine
    // all happen here, OUTSIDE the shard lock and on our own owned copies —
    // exactly the "release before fa.indexNode" contract.
    for (raw_props.items) |rp| {
        const postings = tokenizer.tokenize(allocator, rp.text, rp.key) catch |err| {
            log.warn("fulltext maintain tokenize failed (node {d}, prop '{s}'): {}", .{ node_id, rp.key, err });
            continue;
        };
        if (postings.len == 0) continue;
        doc_terms.appendSlice(allocator, postings) catch |err| {
            tokenizer.freeTermPostings(allocator, postings);
            return err;
        };
        allocator.free(postings); // header only — elements now owned by doc_terms
    }

    if (doc_terms.items.len == 0) return false; // nothing indexable on this node

    if (if_absent) return fa.indexNodeIfAbsent(index_name, node_id, doc_terms.items);
    try fa.indexNode(index_name, node_id, doc_terms.items);
    return true;
}

// ===========================================================================
// Raft apply / snapshot-install FTS maintenance (cluster FTS symmetry,
// 2026-06-10 audit slice 3 — see tests/test_fts_apply_symmetry.zig)
// ===========================================================================
//
// The raft apply path (src/distributed/cluster_replication.zig) and the
// snapshot installer (src/distributed/raft_snapshot_manager.zig) mutate the
// store directly, bypassing the executor's `maintainFulltextOnWrite` call
// sites — so a follower's fulltext indexes silently diverged from the leader.
// Those modules can NOT @import this file (they are compiled in module roots
// where the executor's deps aren't mapped), so they expose callback seams and
// THIS module registers the wrappers below at startup.
//
// THREAD-SAFETY: the apply hook runs on the raft tick thread — a second
// writer beside the executor/connection threads. geode constructs every fts
// engine with `single_writer_thread_check = false`
// (src/storage/fts_storage_adapter.zig) and the engine's internal rw_lock
// serializes all mutators, so cross-thread writes are safe; the
// owning-thread note on `maintainFulltextOnWrite` above describes the
// historical assert that this config disables.

/// Register the FTS maintenance wrappers on the raft apply + snapshot-install
/// seams. Idempotent (re-registering installs the same function pointers).
/// Called once at server startup (src/server/main.zig) and from in-process
/// apply tests that exercise FTS.
pub fn registerFtsApplyHook() void {
    cluster_replication.setFtsApplyHook(&ftsApplyMaintenanceHook);
    cluster_replication.setFtsApplyTextHooks(.{ .removed = &ftsApplyRemovedTextHook, .flush = &ftsApplyFlushHook });
    raft_snapshot_manager.setFtsSnapshotRebuildHook(&ftsSnapshotRebuildHook);
}

// CANARY: REQ=REQ-SONNY-6433-FOLLOWER-FTS-REBUILD; FEATURE="FullText"; ASPECT=ApplyRemovedTextRebuild; STATUS=TESTED; TEST=tests/test_sonny6433_follower_fts_rebuild.zig; OWNER=fts; UPDATED=2026-11-12
/// SONNY-6433: an applied entry took the text in `key` away from a node
/// (see `cluster_replication.FtsApplyTextHooks`): queue the covering indexes
/// for a rebuild, as the executor's SET and REMOVE do.
fn ftsApplyRemovedTextHook(
    store: *graph_store.GraphStore,
    graph_name: []const u8,
    node_id: u64,
    key: []const u8,
) void {
    const global = graph_store.getCurrentGlobalStore() orelse return;
    if (store != global) return;
    const node = store.getNodePtr(node_id) orelse return;
    queueRebuildForRemovedText(graph_name, node.labels, key);
}

/// SONNY-6433: the end of an applied entry: rebuild what it queued
/// (`flushQueuedRebuilds`), on the apply thread, as the executor does at a
/// statement's end. Needs the catalog (the indexes' definitions); without
/// one there is no index to rebuild.
fn ftsApplyFlushHook(store: *graph_store.GraphStore) void {
    const global = graph_store.getCurrentGlobalStore() orelse return;
    if (store != global) return;
    const catalog = @import("../execution.zig").getCatalogInstanceIfPresent() orelse return;
    flushQueuedRebuilds(catalog);
}

/// Apply-path wrapper: resolve the node's labels from the store and run the
/// SAME maintenance the executor runs (`.create` / `.upsert` map directly,
/// `.delete` ↔ executor `.delete` — see the op-semantics note in
/// cluster_replication.zig). Never fails the apply: errors are logged.
fn ftsApplyMaintenanceHook(
    store: *graph_store.GraphStore,
    graph_name: []const u8,
    node_id: u64,
    op: cluster_replication.FtsApplyOp,
) void {
    // Only the process-global store has FTS adapter state; a foreign store
    // (bare codec unit tests applying onto a local GraphStore) has nothing to
    // maintain — and maintainFulltextOnWrite reads properties through the
    // global store, so acting on a foreign store would index the wrong data.
    const global = graph_store.getCurrentGlobalStore() orelse return;
    if (store != global) return;

    // Labels still resolvable for `.delete`: the hook fires pre-delete.
    const node_ptr = store.getNodePtr(node_id) orelse return;

    var arena = std.heap.ArenaAllocator.init(graph_store.global_allocator());
    defer arena.deinit();

    const write_op: FtsWriteOp = switch (op) {
        .create => .create,
        .upsert => .upsert,
        .delete => .delete,
    };
    maintainFulltextOnWrite(arena.allocator(), graph_name, node_id, node_ptr.labels, write_op) catch |err| {
        log.warn("fts maintain (raft apply, {s}) failed for node {d}: {}", .{ @tagName(op), node_id, err });
    };
}

/// Snapshot-install wrapper: drop + recreate + re-backfill every catalogued
/// fulltext index from the restored store. Never fails the install.
///
/// PRECONDITION: no concurrent searches — see `rebuildAllFulltextIndexes`.
fn ftsSnapshotRebuildHook(store: *graph_store.GraphStore) void {
    const global = graph_store.getCurrentGlobalStore() orelse return;
    if (store != global) return;

    var arena = std.heap.ArenaAllocator.init(graph_store.global_allocator());
    defer arena.deinit();

    rebuildAllFulltextIndexes(arena.allocator()) catch |err| {
        log.warn("fts snapshot rebuild failed: {}", .{err});
    };
}

/// Rebuild EVERY catalogued fulltext index on every open graph: drop the
/// engine (on-disk tree included) + cached facade, recreate a fresh engine,
/// and re-backfill from the CURRENT store contents. The label→index registry
/// is left intact (it is the catalog being rebuilt from).
///
/// Why drop+recreate instead of incremental repair: a snapshot install wipes
/// and rewrites the whole store, and fts-storage tombstones are permanent per
/// doc_id (docs/bugs/2026-06-07-fts-search-returns-zero-results-at-runtime.md)
/// — a node deleted pre-snapshot and restored by the snapshot would stay
/// invisible without a fresh engine. Cost: O(total indexed nodes) — accepted;
/// snapshot install is already a full-store rewrite. Per-index failures are
/// logged and skipped so one broken index cannot wedge the install.
///
/// PRECONDITION: no concurrent searches — installSnapshotData currently has
/// NO production caller (reportSnapshot wiring pending); before wiring
/// InstallSnapshot into raft_consensus, the facade/engine drop-recreate here
/// must be made safe against concurrent QUIC-worker searches (unlocked
/// fts_facades map + engine deinit race).
pub fn rebuildAllFulltextIndexes(scratch: std.mem.Allocator) !void {
    const adapter = graph_store.getGlobalAdapter() orelse return;

    const graph_names = try adapter.listOpenGraphNames(scratch);
    for (graph_names) |gname| {
        const mg = adapter.lookupManagedGraph(gname) catch continue;
        const fa = mg.fts_adapter orelse continue; // no FTS on this graph
        // CANARY: REQ=REQ-SONNY-6595-FTS-SNAPSHOT-AFTER-RESTART; FEATURE="FullText"; ASPECT=SnapshotRebuildArmsRegistry; STATUS=TESTED; TEST=tests/test_sonny6595_fts_snapshot_restart.zig; OWNER=fts; UPDATED=2026-11-15
        // SONNY-6595: the registry read below is filled from the catalog by
        // the first write hook after a restart (SONNY-6591); a snapshot
        // installed before any write found it empty and rebuilt nothing.
        armLabelRegistry(adapter, mg, fa, gname);

        const entries = mg.snapshotFtsLabelIndex(scratch) catch |err| {
            log.warn("fts snapshot rebuild: registry copy failed for graph '{s}': {}", .{ gname, err });
            continue;
        };

        // De-dup by index name (the registry is keyed per label; CREATE INDEX
        // registers one label per index, but stay defensive).
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(scratch);

        for (entries) |entry| {
            const gop = try seen.getOrPut(scratch, entry.name);
            if (gop.found_existing) continue;

            // Facade borrows the engine — drop it before the engine.
            mg.dropFulltextFacade(adapter.allocator, entry.name);

            fa.dropIndex(entry.name) catch |err| switch (err) {
                adapter_mod.Error.IndexNotFound => {}, // never opened — fine
                else => {
                    log.warn("fts snapshot rebuild: drop '{s}' on '{s}' failed: {}", .{ entry.name, gname, err });
                    continue;
                },
            };
            fa.createIndex(entry.name) catch |err| {
                log.warn("fts snapshot rebuild: recreate '{s}' on '{s}' failed: {}", .{ entry.name, gname, err });
                continue;
            };

            _ = backfillExistingNodes(scratch, gname, entry.name, entry.label, entry.properties, fa, null) catch |err| {
                log.warn("fts snapshot rebuild: backfill '{s}' on '{s}' failed: {}", .{ entry.name, gname, err });
                continue;
            };

            fa.flush(entry.name) catch |err| {
                log.warn("fts snapshot rebuild: flush '{s}' on '{s}' failed: {}", .{ entry.name, gname, err });
            };
        }
    }
}
