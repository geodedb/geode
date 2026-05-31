const std = @import("std");
const Allocator = std.mem.Allocator;

const adapter_mod = @import("../storage/fts_storage_adapter.zig");
const tokenizer = @import("fts_tokenizer.zig");
const fts = @import("fts_storage_lib");

// Full-text search index — thin facade over the external fts-storage LSM engine
// (via `FtsStorageAdapter`). The in-memory inverted index and the bespoke GFTS
// persistence (`fulltext_persist.zig`) have been removed: durability is owned by
// the lib's WAL + segments + manifest. The public API (init/deinit/search/
// indexDocument/removeDocument) is preserved so existing call sites keep working.
//
// Ownership contract: a `FullTextIndex` does NOT own its `adapter` — the
// per-graph owner (e.g. `ManagedGraph` in graph_storage_adapter.zig) creates the
// adapter and the underlying named index, then constructs the facade via
// `initBacked`. `deinit` only frees the owned `index_name` dupe; it never deinits
// the adapter (the owner does that, in the correct flush→adapter→dir order).
//
// CANARY: REQ=REQ-GQL-FTS-001; FEATURE="BM25 Full-Text Search"; ASPECT=FTS; STATUS=TESTED; TEST=test_fulltext_facade; OWNER=index; UPDATED=2026-05-30
pub const FullTextIndex = struct {
    allocator: Allocator,
    /// Borrowed: owned by the per-graph caller, NOT by this facade.
    adapter: *adapter_mod.FtsStorageAdapter,
    /// Owned dupe of the backing adapter index name.
    index_name: []const u8,

    /// A single search hit. `doc_id == node_id`. `score` is kept as `f64` to
    /// preserve the historical public shape; the adapter Hit carries `f32`.
    /// `highlights` is retained for API compatibility and is always empty
    /// (highlight extraction was never populated by the in-memory path either).
    pub const SearchResult = struct {
        doc_id: u64,
        score: f64,
        highlights: []Highlight,
    };

    pub const Highlight = struct {
        offset: usize,
        length: usize,
        term: []const u8,
    };

    /// Construct a facade over an already-existing adapter index.
    ///
    /// CONTRACT: `adapter` and the index named `index_name` must already exist —
    /// the owner is responsible for `adapter.createIndex`/`openIndex` BEFORE
    /// calling this. The facade dupes `index_name`; it borrows `adapter` and
    /// never destroys it.
    pub fn initBacked(
        allocator: Allocator,
        adapter: *adapter_mod.FtsStorageAdapter,
        index_name: []const u8,
    ) !FullTextIndex {
        const name_copy = try allocator.dupe(u8, index_name);
        return FullTextIndex{
            .allocator = allocator,
            .adapter = adapter,
            .index_name = name_copy,
        };
    }

    /// Free the owned index-name dupe. Does NOT deinit the borrowed adapter.
    pub fn deinit(self: *FullTextIndex) void {
        self.allocator.free(self.index_name);
        self.index_name = &[_]u8{};
    }

    // Index (or re-index) a document by node id. Tokenizes `content` with the
    // shared geode tokenizer (split → NFC+casefold → drop stopwords → group by
    // term) and writes the resulting postings to the backing engine.
    // CANARY: REQ=REQ-GQL-FTS-002; FEATURE="Document Indexing"; ASPECT=FTS; STATUS=TESTED; TEST=test_fulltext_facade; OWNER=index; UPDATED=2026-05-30
    pub fn indexDocument(self: *FullTextIndex, doc_id: u64, content: []const u8) !void {
        const terms = try tokenizer.tokenize(self.allocator, content, null);
        defer tokenizer.freeTermPostings(self.allocator, terms);
        try self.adapter.indexNode(self.index_name, doc_id, terms);
    }

    // Search the backing engine for documents matching `query`.
    //
    // OR semantics, matching the historical in-memory path: the query is
    // tokenized into unique terms, each term is searched independently, and the
    // per-term BM25 hits are merged by node id with their scores summed. Results
    // are sorted by score descending and capped at `max_results`.
    //
    // OWNERSHIP: the returned slice is allocated with `allocator` and is owned by
    // the caller (free with `allocator.free`). This is a cleaner contract than
    // the old in-memory `search`, which returned a slice into a leaked
    // ArrayList. Each `SearchResult.highlights` is the empty static slice (no
    // allocation), so freeing the outer slice is sufficient.
    // CANARY: REQ=REQ-GQL-FTS-001; FEATURE="BM25 Full-Text Search"; ASPECT=FTS; STATUS=TESTED; TEST=test_fulltext_facade; OWNER=index; UPDATED=2026-05-30
    pub fn search(self: *FullTextIndex, query: []const u8, max_results: usize) ![]SearchResult {
        // Tokenize the query with the same pipeline used at index time so query
        // terms match indexed terms exactly (normalization + stopword removal).
        const query_terms = try tokenizer.tokenize(self.allocator, query, null);
        defer tokenizer.freeTermPostings(self.allocator, query_terms);

        // Merge per-term hits by node id, summing score (OR semantics).
        var scores = std.AutoHashMap(u64, f64).init(self.allocator);
        defer scores.deinit();

        for (query_terms) |posting| {
            // 0 = unlimited at the per-term level; the cap is applied after the
            // cross-term merge below so a node strong on a later term is not lost.
            const hits = try self.adapter.search(self.index_name, self.allocator, posting.term, 0);
            defer self.allocator.free(hits);
            for (hits) |hit| {
                const current = scores.get(hit.node_id) orelse 0;
                try scores.put(hit.node_id, current + @as(f64, hit.score));
            }
        }

        var results = std.ArrayList(SearchResult).empty;
        defer results.deinit(self.allocator);
        var it = scores.iterator();
        while (it.next()) |entry| {
            try results.append(self.allocator, .{
                .doc_id = entry.key_ptr.*,
                .score = entry.value_ptr.*,
                .highlights = &[_]Highlight{},
            });
        }

        // Sort by score descending; tie-break on node id ascending for
        // deterministic ordering.
        std.mem.sort(SearchResult, results.items, {}, struct {
            fn lessThan(_: void, lhs: SearchResult, rhs: SearchResult) bool {
                if (lhs.score != rhs.score) return lhs.score > rhs.score;
                return lhs.doc_id < rhs.doc_id;
            }
        }.lessThan);

        const n = if (max_results == 0)
            results.items.len
        else
            @min(max_results, results.items.len);

        const out = try self.allocator.alloc(SearchResult, n);
        @memcpy(out, results.items[0..n]);
        return out;
    }

    // Remove a document (by node id) from the backing engine.
    pub fn removeDocument(self: *FullTextIndex, doc_id: u64) !void {
        try self.adapter.deleteNode(self.index_name, doc_id);
    }

    /// Force a synchronous flush of the backing engine to durable storage.
    /// Durability is otherwise owned by the engine's WAL; this is an explicit
    /// checkpoint for callers that want a hard fsync boundary.
    pub fn flush(self: *FullTextIndex) !void {
        try self.adapter.flush(self.index_name);
    }
};
