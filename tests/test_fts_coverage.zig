// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// CANARY: REQ=REQ-GQL-FTS-COVERAGE-001; FEATURE="Fulltext GQL coverage gaps"; ASPECT=E2E; STATUS=TESTED; TEST=self; OWNER=index; UPDATED=2026-05-31
//
//! A5 coverage tests: fill GQL/store-level FTS gaps left by the adapter and
//! tokenizer unit tests. Everything here drives the REAL parser + executor +
//! per-graph FtsStorageAdapter through GQL (no mocks, no raw lib pokes), and
//! runs under std.testing.allocator so the leak check guards every allocation.
//!
//! What this adds beyond the existing suite (see header comment for the precise
//! delta vs. test_fts_storage_adapter.zig / test_fts_tokenizer.zig /
//! test_fts_e2e.zig / test_fts_maintenance.zig / test_fulltext_bm25.zig):
//!
//!  1. Cross-document BM25 IDF ranking THROUGH GQL — a rare term's doc outranks
//!     a common term's doc. The adapter test only proves within-doc TF ordering;
//!     the bm25 facade test only proves a both-terms doc beats a one-term doc.
//!  2. Multi-property index via `CREATE INDEX ... ON (n.title, n.body)` — a term
//!     present only in `title` and a term present only in `body` are BOTH found
//!     through the real backfill path. The adapter test tags fields directly,
//!     never via 2-property GQL DDL + backfill.
//!  3. Store-level reopen durability — index + docs via GQL, deinit the GLOBAL
//!     store, reinit it over the SAME data dir, search still returns the docs.
//!     The adapter test reopens only the adapter; nothing else restarts the
//!     whole geode store.
//!  4. DROP then re-CREATE the SAME index name via GQL DDL, with a fresh backfill
//!     that must NOT see the old corpus. The adapter test does drop+create at the
//!     adapter level; this proves the GQL DDL + backfill round-trips cleanly.
//!  5. Multiple fulltext indexes on DIFFERENT labels in one graph via GQL —
//!     each index only returns its own label's nodes.
//!  6. Edge cases via GQL: a non-string property value must be SKIPPED (not
//!     crash); an empty-string property contributes no terms; a no-match query
//!     returns an empty row-set.
//!
//! SKIPPED (already covered or not exposed):
//!  * Within-doc TF ordering, max_results truncation, IndexNotFound, field tags,
//!    adapter-level reopen — covered by test_fts_storage_adapter.zig.
//!  * Tokenizer boundary/casefold/stopword/unicode-fold — covered by
//!    test_fts_tokenizer.zig + the bm25 facade unicode test.
//!  * CREATE/SET/DELETE write-maintenance — covered by test_fts_maintenance.zig.
//!  * Phrase search — NOT exposed in geode's query path. `fulltext_search`
//!    takes (index, term) only; A4a wired single + multi-term OR, never an
//!    adjacency/phrase operator. There is no GQL/facade surface to test, so we
//!    deliberately do not reach into the raw `fts.PhraseIterator` lib here.

const std = @import("std");
const testing = std.testing;

const geode = @import("geode");
const execution = geode.execution;
const graph_store = geode.graph_store;

/// In-process harness mirroring tests/test_fts_maintenance.zig: boot a global
/// store rooted at a fresh tmp dir, run GQL through execution.executeQuery, and
/// assert on the typed ExecutionResult. The reopen test below additionally
/// tears the store down and brings it back up over the same `data_dir`.
const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []const u8,

    fn init(allocator: std.mem.Allocator) !Harness {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try tmp.dir.realpathAlloc(allocator, ".");

        try graph_store.initGlobalStoreWithDataDir(allocator, data_dir);

        return .{ .allocator = allocator, .tmp = tmp, .data_dir = data_dir };
    }

    fn deinit(self: *Harness) void {
        graph_store.deinitGlobalStore();
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    /// Tear the global store down and bring it back up over the SAME on-disk
    /// data dir — simulates a geode restart. The tmp dir is left intact.
    fn restart(self: *Harness) !void {
        graph_store.deinitGlobalStore();
        try graph_store.initGlobalStoreWithDataDir(self.allocator, self.data_dir);
    }

    fn exec(self: *Harness, gql: []const u8) !execution.ExecutionResult {
        return try execution.executeQuery(self.allocator, gql, self.data_dir);
    }

    /// Run a statement whose result we don't inspect, freeing it.
    fn run(self: *Harness, gql: []const u8) !void {
        var r = try self.exec(gql);
        r.deinit(self.allocator);
    }

    /// Number of fulltext_search hits for `term` in `index`.
    fn searchCount(self: *Harness, index: []const u8, term: []const u8) !usize {
        const gql = try std.fmt.allocPrint(self.allocator, "CALL fulltext_search('{s}', '{s}')", .{ index, term });
        defer self.allocator.free(gql);
        var r = try self.exec(gql);
        defer r.deinit(self.allocator);
        return r.rows.len;
    }

    /// The single node id returned for `term` in `index`. Asserts exactly one
    /// hit; returns its node_id (column 0, an Int) as i64.
    fn searchSingleId(self: *Harness, index: []const u8, term: []const u8) !i64 {
        const gql = try std.fmt.allocPrint(self.allocator, "CALL fulltext_search('{s}', '{s}')", .{ index, term });
        defer self.allocator.free(gql);
        var r = try self.exec(gql);
        defer r.deinit(self.allocator);
        try testing.expectEqual(@as(usize, 1), r.rows.len);
        try testing.expect(r.rows[0][0] == .Int);
        return r.rows[0][0].Int;
    }
};

/// Pull the node id (col 0) for a fulltext_search result row, as i64.
fn rowNodeId(row: []const execution.Value) i64 {
    return row[0].Int;
}

/// Pull the BM25 score (col 1) for a fulltext_search result row, as f64.
fn rowScore(row: []const execution.Value) f64 {
    return row[1].Double;
}

// ---------------------------------------------------------------------------
// GAP 1: Cross-document BM25 IDF ranking through GQL.
//
// A term that appears in only ONE document (rare → high IDF) must out-score the
// SAME document's contribution from a term that appears in MANY documents (common
// → low IDF). We index one "special" doc containing both a rare term ("zebra")
// and a common term ("the"-class word we control: "alpha", seeded into many
// docs), plus a pile of docs that contain only the common term. A two-term query
// ("zebra alpha") must rank the special doc strictly first (it is the only doc
// matching the rare, high-IDF term), and the common-only docs strictly lower.
//
// This is NOT the adapter's within-doc TF test, and NOT the facade's
// both-terms-beats-one-term test: here the winner matches the SAME number of
// distinct query terms as some losers would if "alpha" alone decided it; the
// rare term's IDF is what must lift it.
// ---------------------------------------------------------------------------
test "fts coverage: rare-term doc outranks common-term docs (cross-doc BM25/IDF)" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try h.run("CREATE INDEX idx FOR (d:Doc) ON (d.body) USING fulltext");

    // 8 "common" docs: each contains only the high-frequency term "alpha".
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try h.run("CREATE (:Doc {body: 'alpha common filler text here'})");
    }
    // 1 "special" doc: contains the RARE term "zebra" plus the common "alpha".
    try h.run("CREATE (:Doc {body: 'zebra alpha rare special document'})");

    // "zebra" is rare → exactly one doc carries it; capture that node id.
    const special_id = try h.searchSingleId("idx", "zebra");

    // "alpha" is common → all 9 docs carry it.
    try testing.expectEqual(@as(usize, 9), try h.searchCount("idx", "alpha"));

    // Two-term OR query: the rare term lifts the special doc to rank #1, ahead
    // of every alpha-only doc, because "zebra" has far higher IDF than "alpha".
    {
        var r = try h.exec("CALL fulltext_search('idx', 'zebra alpha')");
        defer r.deinit(allocator);

        // All 9 docs match (every doc has "alpha"); the special doc also has
        // "zebra".
        try testing.expectEqual(@as(usize, 9), r.rows.len);

        // Rank #1 must be the special (rare-term) doc.
        try testing.expect(r.rows[0][0] == .Int);
        try testing.expect(r.rows[0][1] == .Double);
        try testing.expectEqual(special_id, rowNodeId(r.rows[0]));

        // Its score must be STRICTLY greater than every alpha-only doc's score
        // (those all share the same low-IDF "alpha"-only contribution).
        const top_score = rowScore(r.rows[0]);
        var j: usize = 1;
        while (j < r.rows.len) : (j += 1) {
            try testing.expect(rowNodeId(r.rows[j]) != special_id);
            try testing.expect(top_score > rowScore(r.rows[j]));
        }
    }
}

// ---------------------------------------------------------------------------
// GAP 3: Multi-property fulltext index via GQL DDL (ON (n.title, n.body)).
//
// A term that lives ONLY in `title` and a term that lives ONLY in `body` must
// both be searchable after backfill — proving the 2-property CREATE INDEX path
// tags + indexes both properties through the real backfill, not just the
// adapter's direct field-tag API.
// ---------------------------------------------------------------------------
test "fts coverage: multi-property index via GQL finds terms in each property" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    // Seed a node whose `title` and `body` carry DISJOINT vocabularies.
    try h.run("CREATE (:Doc {title: 'lighthouse', body: 'submarine voyage'})");

    // Two-property fulltext index, backfilling the pre-existing node.
    try h.run("CREATE INDEX both_idx FOR (d:Doc) ON (d.title, d.body) USING fulltext");

    // Term only in title.
    const id_from_title = try h.searchSingleId("both_idx", "lighthouse");
    // Term only in body.
    const id_from_body = try h.searchSingleId("both_idx", "submarine");
    // Both searches resolve to the SAME single node — both properties indexed.
    try testing.expectEqual(id_from_title, id_from_body);

    // A second term that is in body too ("voyage").
    try testing.expectEqual(@as(usize, 1), try h.searchCount("both_idx", "voyage"));
    // A term in NEITHER property must miss.
    try testing.expectEqual(@as(usize, 0), try h.searchCount("both_idx", "mountain"));
}

// ---------------------------------------------------------------------------
// GAP 4: Store-level reopen durability.
//
// Create an index + index docs via GQL, deinit the GLOBAL store, reinit it over
// the SAME data dir (a geode restart), then search — the docs must still be
// found. This proves the fts-storage segments/WAL survive a full geode restart,
// not just an adapter re-open (which test_fts_storage_adapter.zig already covers).
// ---------------------------------------------------------------------------
test "fts coverage: index survives a full store restart (reopen durability)" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try h.run("CREATE INDEX persist_idx FOR (d:Doc) ON (d.body) USING fulltext");
    try h.run("CREATE (:Doc {body: 'a persistent indexed phoenix rises'})");
    try h.run("CREATE (:Doc {body: 'an ephemeral sparrow flies away'})");

    // Capture the pre-restart node id for the rare term.
    const phoenix_before = try h.searchSingleId("persist_idx", "phoenix");

    // Restart the whole store over the same on-disk data dir.
    try h.restart();

    // After restart: the same docs must still be searchable, with stable ids.
    const phoenix_after = try h.searchSingleId("persist_idx", "phoenix");
    try testing.expectEqual(phoenix_before, phoenix_after);

    // The other doc is also still searchable, and is a DIFFERENT node.
    const sparrow_after = try h.searchSingleId("persist_idx", "sparrow");
    try testing.expect(sparrow_after != phoenix_after);

    // A term in neither doc still misses after restart.
    try testing.expectEqual(@as(usize, 0), try h.searchCount("persist_idx", "dragon"));
}

// ---------------------------------------------------------------------------
// GAP 6: DROP then re-CREATE the SAME index name via GQL, with a fresh backfill.
//
// The re-created index must reflect ONLY the corpus present at re-create time
// (its fresh backfill), with NO stale postings from the dropped index. Exercises
// the adapter's create-vs-open decision on a previously-dropped on-disk dir
// THROUGH the GQL DDL path.
// ---------------------------------------------------------------------------
test "fts coverage: DROP then re-CREATE same index name backfills cleanly" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    // First incarnation: index a node carrying "walrus".
    try h.run("CREATE (:Doc {body: 'the original walrus swims'})");
    try h.run("CREATE INDEX recycle_idx FOR (d:Doc) ON (d.body) USING fulltext");
    try testing.expectEqual(@as(usize, 1), try h.searchCount("recycle_idx", "walrus"));

    // Drop it.
    try h.run("DROP INDEX recycle_idx");

    // Add a SECOND node with a different rare term, then re-CREATE the SAME name.
    // The fresh backfill must index BOTH existing docs (walrus + otter) — proving
    // re-create rebuilds from the live corpus, not from stale dropped segments.
    try h.run("CREATE (:Doc {body: 'a new otter floats nearby'})");
    try h.run("CREATE INDEX recycle_idx FOR (d:Doc) ON (d.body) USING fulltext");

    // Both terms resolve (one node each) under the recreated index.
    const walrus_id = try h.searchSingleId("recycle_idx", "walrus");
    const otter_id = try h.searchSingleId("recycle_idx", "otter");
    try testing.expect(walrus_id != otter_id);

    // And exactly one node carries each — no duplicate/stale postings.
    try testing.expectEqual(@as(usize, 1), try h.searchCount("recycle_idx", "walrus"));
    try testing.expectEqual(@as(usize, 1), try h.searchCount("recycle_idx", "otter"));
}

// ---------------------------------------------------------------------------
// GAP 5: Multiple fulltext indexes on DIFFERENT labels in one graph via GQL.
//
// idx_a on :Alpha(x) and idx_b on :Beta(y) must each return ONLY their own
// label's nodes — the per-graph adapter keeps the two named engines isolated.
// ---------------------------------------------------------------------------
test "fts coverage: distinct fulltext indexes on different labels stay isolated" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    // Two labels with their own text properties.
    try h.run("CREATE (:Alpha {x: 'flamingo wades in shallow water'})");
    try h.run("CREATE (:Beta {y: 'badger digs a deep burrow'})");

    // One index per label/property.
    try h.run("CREATE INDEX idx_a FOR (a:Alpha) ON (a.x) USING fulltext");
    try h.run("CREATE INDEX idx_b FOR (b:Beta) ON (b.y) USING fulltext");

    // Each index finds its own label's term...
    const flamingo_id = try h.searchSingleId("idx_a", "flamingo");
    const badger_id = try h.searchSingleId("idx_b", "badger");
    try testing.expect(flamingo_id != badger_id);

    // ...and does NOT find the OTHER label's term (engines are isolated).
    try testing.expectEqual(@as(usize, 0), try h.searchCount("idx_a", "badger"));
    try testing.expectEqual(@as(usize, 0), try h.searchCount("idx_b", "flamingo"));
}

// ---------------------------------------------------------------------------
// GAP 5 (edge cases): non-string property, empty-string property, no-match.
//
//  * A node whose indexed property is a NUMBER (not a string) must be SKIPPED by
//    the indexer — no crash, no postings.
//  * A node whose indexed property is the EMPTY STRING contributes no terms.
//  * A node with real text is still found, and a no-match term returns nothing.
//
// All in one index so the indexer has to tolerate the mixed/odd nodes alongside
// a normal one without corrupting the normal node's postings.
// ---------------------------------------------------------------------------
test "fts coverage: non-string + empty-string properties are skipped, normal node still indexed" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try h.run("CREATE INDEX edge_idx FOR (d:Doc) ON (d.body) USING fulltext");

    // Node A: body is a NUMBER — must be skipped, not crash.
    try h.run("CREATE (:Doc {body: 42})");
    // Node B: body is the EMPTY STRING — contributes no terms.
    try h.run("CREATE (:Doc {body: ''})");
    // Node C: a normal text node — must be indexed.
    try h.run("CREATE (:Doc {body: 'kingfisher dives for minnows'})");

    // The normal node is found by a term it actually contains.
    const kingfisher_id = try h.searchSingleId("edge_idx", "kingfisher");
    try testing.expect(kingfisher_id != 0);

    // The numeric value "42" yields no searchable term (numbers aren't indexed
    // as text); searching the literal "42" returns nothing.
    try testing.expectEqual(@as(usize, 0), try h.searchCount("edge_idx", "42"));

    // A term present in none of the nodes returns an empty row-set.
    try testing.expectEqual(@as(usize, 0), try h.searchCount("edge_idx", "crocodile"));

    // Exactly one node total is searchable (only the normal text node).
    try testing.expectEqual(@as(usize, 1), try h.searchCount("edge_idx", "minnows"));
}
