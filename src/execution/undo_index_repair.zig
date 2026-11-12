// CANARY: REQ=REQ-SONNY-3381-UNDO-INDEX-REPAIR; FEATURE="Execution"; ASPECT=UndoIndexRepairHook; STATUS=TESTED; TEST=tests/test_sonny3381_undo_index_entries.zig; OWNER=execution; UPDATED=2026-11-12
//! SONNY-3381: after an undo, rebuild the indexes the executor keeps beside
//! the graph store.
//!
//! A failed statement's replay (`statement_undo`) and ROLLBACK / ROLLBACK TO
//! SAVEPOINT (`txn_undo_log.UndoLog`) undo through the store's write methods.
//! The full-text indexes and the advanced (vector, spatial, network, ...)
//! indexes are maintained by the executor around those methods instead
//! (`property_mutation.setNodePropertyFromValue`, the CREATE and DELETE
//! paths), and neither can take back one change: the full-text engine is
//! append-only with permanent per-document tombstones, and HNSW has no
//! remove. The undo collects the (graph, label, property) of every node
//! change it reverts (`txn_undo_log.IndexRepair`); this hook rebuilds every
//! index covering one of them from the store as the undo left it, so a
//! search after a failed statement or a ROLLBACK answers for what the store
//! holds.
//!
//! Runs on the undoing thread, under the graph lock its statement or
//! transaction holds: a graph lock, then the advanced-index `rebuild_mutex`
//! (tier 1 -> 1.5) and the catalog's read lock (tier 2), in the lock-ordering
//! table's order; it takes no graph lock. The full-text engines are built
//! with the single-writer thread check off (`fts_storage_adapter`), and the
//! rebuild's window queues a concurrent writer's node instead of racing the
//! drop and recreate (`fts_index_ops.rebuildFulltextIndex`).
//!
//! Cost: a rebuild is O(nodes of the label). It runs only for an undo that
//! reverted a change to a property, label or node an index covers.

const std = @import("std");
const graph_store = @import("../graph_store.zig");
const txn_undo_log = @import("../txn_undo_log.zig");
const index_manager = @import("../index/index_manager.zig");
const fts_index_ops = @import("fts_index_ops.zig");
const execution = @import("../execution.zig");
const logging = @import("logging");
const log = logging.scoped("undo_index_repair");
const Attr = logging.Attr;

const Target = txn_undo_log.IndexRepair.Target;

/// Indexes rebuilt after an undo, and rebuilds that failed (tests,
/// diagnostics).
pub var rebuilt_total: std.atomic.Value(u64) = .init(0);
pub var failed_total: std.atomic.Value(u64) = .init(0);

/// Install the hook (`execution.beginStatementScope`; idempotent).
pub fn install() void {
    txn_undo_log.setIndexRepairHook(&repair);
}

fn repair(store: *graph_store.GraphStore, targets: []const Target, everything: bool) void {
    var arena = std.heap.ArenaAllocator.init(graph_store.global_allocator());
    defer arena.deinit();
    repairAdvancedIndexes(arena.allocator(), store, targets, everything) catch |err| noteFailure("advanced", "*", err);
    repairFulltextIndexes(arena.allocator(), targets, everything) catch |err| noteFailure("fulltext", "*", err);
}

fn noteFailure(kind: []const u8, name: []const u8, err: anyerror) void {
    _ = failed_total.fetchAdd(1, .monotonic);
    log.err("an index the undo left stale could not be rebuilt; it answers for the undone value until it is rebuilt", &.{
        Attr.string("kind", kind),
        Attr.string("index", name),
        Attr.string("error", @errorName(err)),
    });
}

fn covers(targets: []const Target, everything: bool, graph: ?[]const u8, label: []const u8, properties: []const []const u8) bool {
    if (everything) return true;
    for (targets) |t| {
        if (graph) |g| if (!std.mem.eql(u8, t.graph, g)) continue;
        if (!std.mem.eql(u8, t.label, label)) continue;
        const p = t.property orelse return true;
        for (properties) |q| if (std.mem.eql(u8, p, q)) return true;
    }
    return false;
}

/// The advanced indexes (one label, one property each, graph-wide) that
/// cover a target. Their names are copied under the registry's mutex, which
/// is released before any rebuild (`rebuildAdvancedIndex` takes it itself).
fn repairAdvancedIndexes(a: std.mem.Allocator, store: *graph_store.GraphStore, targets: []const Target, everything: bool) !void {
    const manager = index_manager.getGlobalIndexManager() orelse return;
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    {
        const io = std.Io.Threaded.global_single_threaded.io();
        manager.rebuild_mutex.lockUncancelable(io);
        defer manager.rebuild_mutex.unlock(io);
        var it = manager.advanced_property_indexes.iterator();
        while (it.next()) |entry| {
            const meta = entry.value_ptr.*;
            if (!covers(targets, everything, null, meta.label, &.{meta.property})) continue;
            try names.append(a, try a.dupe(u8, meta.name));
        }
    }
    for (names.items) |name| {
        txn_undo_log.dropPendingAdvancedIndexRebuild(name);
        manager.rebuildAdvancedIndex(store, name) catch |err| {
            noteFailure("advanced", name, err);
            continue;
        };
        _ = rebuilt_total.fetchAdd(1, .monotonic);
    }
}

/// The full-text indexes of each target's graph that cover it.
fn repairFulltextIndexes(a: std.mem.Allocator, targets: []const Target, everything: bool) !void {
    const adapter = graph_store.getGlobalAdapter() orelse return;
    const catalog = if (execution.getActiveContext()) |ctx| ctx.catalog else (execution.getCatalogInstanceIfPresent() orelse return);

    var graphs: std.ArrayListUnmanaged([]const u8) = .empty;
    if (everything) {
        try graphs.appendSlice(a, try adapter.listOpenGraphNames(a));
    } else for (targets) |t| {
        for (graphs.items) |g| {
            if (std.mem.eql(u8, g, t.graph)) break;
        } else try graphs.append(a, t.graph);
    }

    for (graphs.items) |gname| {
        const mg = adapter.lookupManagedGraph(gname) catch continue;
        if (mg.fts_adapter == null) continue;
        const entries = try mg.snapshotFtsLabelIndex(a);
        var done: std.StringHashMapUnmanaged(void) = .empty;
        for (entries) |entry| {
            if (!covers(targets, everything, gname, entry.label, entry.properties)) continue;
            if ((try done.getOrPut(a, entry.name)).found_existing) continue;
            _ = fts_index_ops.rebuildFulltextIndex(a, catalog, gname, entry.name) catch |err| {
                noteFailure("fulltext", entry.name, err);
                continue;
            };
            _ = rebuilt_total.fetchAdd(1, .monotonic);
        }
    }
}
