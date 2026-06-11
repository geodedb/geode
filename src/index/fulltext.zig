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

    // ------------------------------------------------------------------
    // Advanced FTS: phrase / proximity / highlight over the REAL engine
    // (GAP-0869). All three operate on the persisted fts-storage postings —
    // the engine stores token-positions per (term, doc) and the geode
    // tokenizer assigns raw-stream ordinals BEFORE stopword removal, so
    // phrase alignment survives stopword gaps at both index and query time.
    // ------------------------------------------------------------------

    /// Per-term positional candidate map used by phrase/proximity. Maps
    /// node_id -> (score, positions) for one term.
    const TermDocs = struct {
        hits: []adapter_mod.PositionalHit,

        fn find(self: TermDocs, node_id: u64) ?adapter_mod.PositionalHit {
            // hits are sorted by node_id ascending (adapter contract).
            var lo: usize = 0;
            var hi: usize = self.hits.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (self.hits[mid].node_id < node_id) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if (lo < self.hits.len and self.hits[lo].node_id == node_id) return self.hits[lo];
            return null;
        }
    };

    fn containsPosition(positions: []const u32, want: u32) bool {
        var lo: usize = 0;
        var hi: usize = positions.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (positions[mid] < want) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo < positions.len and positions[lo] == want;
    }

    /// Search for documents containing `phrase` as adjacent terms (in raw
    /// token order, with stopword gaps preserved on BOTH sides — e.g. the
    /// phrase "quick and brown" matches a document indexed from
    /// "quick and brown" because "and" occupies ordinal 1 in both streams
    /// even though it is never indexed).
    ///
    /// Verification runs against the engine's persisted token-positions
    /// (`searchPositions`), NOT against any synthetic corpus. Score is the
    /// sum of the constituent terms' BM25 scores for the matching document.
    /// Caller owns the result; free with `self.allocator.free`.
    // CANARY: REQ=REQ-GQL-FTS-ADV-001; FEATURE="Advanced FTS"; ASPECT=PhraseSearch; STATUS=TESTED; TEST=tests/e2e_fts_advanced.zig; OWNER=index; UPDATED=2026-06-10
    pub fn phraseSearch(self: *FullTextIndex, phrase: []const u8, max_results: usize) ![]SearchResult {
        return self.positionalSearch(phrase, .{ .phrase = {} }, max_results);
    }

    /// Search for documents containing ALL terms of `query` within a token
    /// window of `distance` (inclusive, in raw-token ordinals: a document
    /// matches when one occurrence of each distinct term can be chosen such
    /// that max(pos) - min(pos) <= distance). Order-insensitive NEAR
    /// semantics. Requires at least 2 distinct (non-stopword) terms.
    // CANARY: REQ=REQ-GQL-FTS-ADV-001; FEATURE="Advanced FTS"; ASPECT=ProximitySearch; STATUS=TESTED; TEST=tests/e2e_fts_advanced.zig; OWNER=index; UPDATED=2026-06-10
    pub fn proximitySearch(self: *FullTextIndex, query: []const u8, distance: u32, max_results: usize) ![]SearchResult {
        return self.positionalSearch(query, .{ .proximity = distance }, max_results);
    }

    const PositionalMode = union(enum) {
        phrase: void,
        proximity: u32,
    };

    fn positionalSearch(
        self: *FullTextIndex,
        query: []const u8,
        mode: PositionalMode,
        max_results: usize,
    ) ![]SearchResult {
        const a = self.allocator;

        // Ordered query tokens (normalized, raw ordinals, stopwords dropped
        // but their ordinal gaps preserved) — same pipeline as index time.
        const q_tokens = try tokenizer.tokenizeOrdered(a, query);
        defer tokenizer.freeOrderedTokens(a, q_tokens);

        switch (mode) {
            .phrase => if (q_tokens.len == 0) return try a.alloc(SearchResult, 0),
            .proximity => {
                // Proximity needs >= 2 DISTINCT terms to be meaningful.
                var distinct: usize = 0;
                outer: for (q_tokens, 0..) |t, i| {
                    for (q_tokens[0..i]) |prev| {
                        if (std.mem.eql(u8, prev.term, t.term)) continue :outer;
                    }
                    distinct += 1;
                }
                if (distinct < 2) return error.TooFewTerms;
            },
        }

        // Fetch positional hits ONCE per unique term.
        var term_docs = std.StringHashMap(TermDocs).init(a);
        defer {
            var it = term_docs.valueIterator();
            while (it.next()) |td| adapter_mod.freePositionalHits(a, td.hits);
            term_docs.deinit();
        }
        for (q_tokens) |t| {
            if (term_docs.contains(t.term)) continue;
            const hits = try self.adapter.searchPositions(self.index_name, a, t.term);
            errdefer adapter_mod.freePositionalHits(a, hits);
            try term_docs.put(t.term, .{ .hits = hits });
        }

        // Candidate docs = docs matching the FIRST query token's term (any
        // phrase/proximity match must contain every term, so the first term's
        // doc list is a complete candidate superset).
        const lead = term_docs.get(q_tokens[0].term).?;

        var results = std.ArrayList(SearchResult).empty;
        defer results.deinit(a);

        candidate: for (lead.hits) |cand| {
            // Every term must be present in this doc; accumulate the score.
            var score: f64 = 0;
            for (q_tokens, 0..) |t, i| {
                // Score each DISTINCT term once (first occurrence in query).
                var seen_before = false;
                for (q_tokens[0..i]) |prev| {
                    if (std.mem.eql(u8, prev.term, t.term)) {
                        seen_before = true;
                        break;
                    }
                }
                if (seen_before) continue;
                const td = term_docs.get(t.term).?;
                const hit = td.find(cand.node_id) orelse continue :candidate;
                score += @as(f64, hit.score);
            }

            const matched = switch (mode) {
                .phrase => try self.checkPhrase(q_tokens, term_docs, cand),
                .proximity => |dist| try self.checkProximity(q_tokens, term_docs, cand.node_id, dist),
            };
            if (!matched) continue;

            try results.append(a, .{
                .doc_id = cand.node_id,
                .score = score,
                .highlights = &[_]Highlight{},
            });
        }

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

        const out = try a.alloc(SearchResult, n);
        @memcpy(out, results.items[0..n]);
        return out;
    }

    /// True iff `cand.node_id` contains the query tokens at relative offsets
    /// matching their raw query ordinals: there exists a base position such
    /// that token k (query ordinal o_k) appears at base + (o_k - o_0).
    fn checkPhrase(
        self: *FullTextIndex,
        q_tokens: []const tokenizer.OrderedToken,
        term_docs: std.StringHashMap(TermDocs),
        cand: adapter_mod.PositionalHit,
    ) !bool {
        _ = self;
        const o0 = q_tokens[0].ordinal;
        base: for (cand.positions) |p0| {
            for (q_tokens[1..]) |t| {
                const delta = t.ordinal - o0;
                const want = p0 +% delta;
                const td = term_docs.get(t.term).?;
                const hit = td.find(cand.node_id) orelse return false;
                if (!containsPosition(hit.positions, want)) continue :base;
            }
            return true;
        }
        return false;
    }

    /// True iff one occurrence of each DISTINCT query term can be chosen in
    /// `node_id` with max(pos) - min(pos) <= distance. Minimal-covering-window
    /// sweep over the merged (position, term) stream.
    fn checkProximity(
        self: *FullTextIndex,
        q_tokens: []const tokenizer.OrderedToken,
        term_docs: std.StringHashMap(TermDocs),
        node_id: u64,
        distance: u32,
    ) !bool {
        const a = self.allocator;

        // Distinct terms, first-seen order.
        var terms: std.ArrayListUnmanaged([]const u8) = .empty;
        defer terms.deinit(a);
        outer: for (q_tokens) |t| {
            for (terms.items) |existing| {
                if (std.mem.eql(u8, existing, t.term)) continue :outer;
            }
            try terms.append(a, t.term);
        }

        const Entry = struct { pos: u32, term_idx: usize };
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        defer entries.deinit(a);

        for (terms.items, 0..) |term, idx| {
            const td = term_docs.get(term).?;
            const hit = td.find(node_id) orelse return false;
            for (hit.positions) |p| {
                try entries.append(a, .{ .pos = p, .term_idx = idx });
            }
        }

        std.mem.sort(Entry, entries.items, {}, struct {
            fn lessThan(_: void, x: Entry, y: Entry) bool {
                return x.pos < y.pos;
            }
        }.lessThan);

        // Two-pointer minimal covering window over the merged stream.
        const counts = try a.alloc(usize, terms.items.len);
        defer a.free(counts);
        @memset(counts, 0);

        var covered: usize = 0;
        var left: usize = 0;
        for (entries.items, 0..) |e, right| {
            if (counts[e.term_idx] == 0) covered += 1;
            counts[e.term_idx] += 1;

            while (covered == terms.items.len) {
                const span = entries.items[right].pos - entries.items[left].pos;
                if (span <= distance) return true;
                const l = entries.items[left];
                counts[l.term_idx] -= 1;
                if (counts[l.term_idx] == 0) covered -= 1;
                left += 1;
            }
        }
        return false;
    }

    /// Compute byte-accurate highlight ranges for `query`'s terms inside
    /// `content`. `content` is the AUTHORIZED document text supplied by the
    /// caller — highlight/snippet generation must run AFTER row-level
    /// authorization (RLS/FLE), so this function never fetches document
    /// content itself; it only maps token matches to byte offsets in what the
    /// caller was already cleared to read.
    ///
    /// Matching uses the index-time pipeline (NFC + case-fold + stopword
    /// rules) on both sides, so "Fox" in content matches query term "fox".
    /// Returned `Highlight.term` slices point INTO `content` (the raw matched
    /// bytes); the result outer slice is owned by the caller (free with
    /// `allocator.free`), no per-entry frees needed. Sorted by offset.
    // CANARY: REQ=REQ-GQL-FTS-ADV-001; FEATURE="Advanced FTS"; ASPECT=Highlight; STATUS=TESTED; TEST=tests/e2e_fts_advanced.zig; OWNER=index; UPDATED=2026-06-10
    pub fn highlight(
        allocator: Allocator,
        content: []const u8,
        query: []const u8,
    ) ![]Highlight {
        const q_tokens = try tokenizer.tokenizeOrdered(allocator, query);
        defer tokenizer.freeOrderedTokens(allocator, q_tokens);

        const c_tokens = try tokenizer.tokenizeOrdered(allocator, content);
        defer tokenizer.freeOrderedTokens(allocator, c_tokens);

        var out: std.ArrayListUnmanaged(Highlight) = .empty;
        defer out.deinit(allocator);

        for (c_tokens) |ct| {
            for (q_tokens) |qt| {
                if (std.mem.eql(u8, ct.term, qt.term)) {
                    try out.append(allocator, .{
                        .offset = ct.byte_start,
                        .length = ct.byte_end - ct.byte_start,
                        .term = content[ct.byte_start..ct.byte_end],
                    });
                    break;
                }
            }
        }

        const result = try allocator.alloc(Highlight, out.items.len);
        @memcpy(result, out.items);
        return result;
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
