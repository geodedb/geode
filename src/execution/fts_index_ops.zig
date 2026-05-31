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

const log = std.log.scoped(.fts_index_ops);

pub const Error = error{
    /// The fulltext index name already exists (and IF NOT EXISTS was absent).
    FulltextIndexExists,
    /// FTS is unavailable on the resolved graph (adapter not initialised).
    FulltextUnavailable,
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

    // Resolve the ManagedGraph that owns the fts adapter for this graph. Use the
    // test-friendly lookup (brief mutex, no lock acquisition) — backfill reads
    // node properties through the global store, not through this handle.
    const mg = adapter.lookupManagedGraph(graph_name) catch return Error.FulltextUnavailable;
    const fa = mg.fts_adapter orelse return Error.FulltextUnavailable;

    // Create the engine. Treat "already exists" per IF NOT EXISTS.
    fa.createIndex(index_name) catch |err| switch (err) {
        adapter_mod.Error.IndexExists => {
            // Idempotent create requested → done (do NOT re-backfill: re-indexing
            // would duplicate postings in the append-only engine).
            return;
        },
        else => return err,
    };
    errdefer fa.dropIndex(index_name) catch {};

    try backfillExistingNodes(allocator, graph_name, index_name, label, properties, fa);

    // Durability + segment formation. The same-process search path sees memtable
    // writes without this, but a flush hardens the WAL into a segment.
    fa.flush(index_name) catch |err| {
        log.warn("fulltext backfill flush failed for '{s}': {}", .{ index_name, err });
    };
}

/// Backfill loop, factored out so the create path stays readable.
fn backfillExistingNodes(
    allocator: std.mem.Allocator,
    graph_name: []const u8,
    index_name: []const u8,
    label: []const u8,
    properties: []const []const u8,
    fa: *adapter_mod.FtsStorageAdapter,
) !void {
    const store = graph_store.getGlobalStore(graph_store.global_allocator());

    // Borrowed posting list of node ids for this (graph, label); null = no nodes.
    const node_ids = store.getNodesByLabel(graph_name, label) orelse return;

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

        fa.indexNode(index_name, node_id, doc_terms.items) catch |err| {
            log.warn("fulltext backfill indexNode failed (node {d}): {}", .{ node_id, err });
        };
    }
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

    fa.dropIndex(index_name) catch |err| switch (err) {
        adapter_mod.Error.IndexNotFound => {
            if (!if_exists) return err;
        },
        else => return err,
    };
}
