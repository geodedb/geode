// GAP-0869: Advanced FTS (phrase / proximity / highlight) over the REAL
// persisted fts-storage index. The former version of this file asserted
// against hard-coded synthetic corpora inside src/fts/advanced.zig — those
// stubs were deleted. Every test here drives real documents through the real
// tokenizer -> adapter -> fts-storage engine pipeline and verifies the
// positional semantics against what was actually indexed.
//
// CANARY: REQ=REQ-GQL-FTS-ADV-001; FEATURE="Advanced FTS"; ASPECT=E2E; STATUS=TESTED; TEST=tests/e2e_fts_advanced.zig; OWNER=index; UPDATED=2026-06-10

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const FtsStorageAdapter = geode.index.fts_storage_adapter.FtsStorageAdapter;
const FullTextIndex = geode.index.fulltext.FullTextIndex;

/// Real-engine harness: a named fts-storage index in a tmp dir wrapped by the
/// FullTextIndex facade (same construction the per-graph owner performs).
const Harness = struct {
    tmp: std.testing.TmpDir,
    io: std.Io,
    base_dir: std.Io.Dir,
    adapter: *FtsStorageAdapter,
    facade: FullTextIndex,

    fn init(alloc: std.mem.Allocator) !Harness {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const io = std.Io.Threaded.global_single_threaded.io();

        const base_dir = try tmp.dir.createDirPathOpen(io, "fts", .{});

        const adapter = try FtsStorageAdapter.init(alloc, io, base_dir, "fts");
        errdefer adapter.deinit();

        try adapter.createIndex("adv_idx");
        const facade = try FullTextIndex.initBacked(alloc, adapter, "adv_idx");

        return .{
            .tmp = tmp,
            .io = io,
            .base_dir = base_dir,
            .adapter = adapter,
            .facade = facade,
        };
    }

    fn deinit(self: *Harness) void {
        self.facade.deinit();
        self.adapter.deinit();
        self.base_dir.close(self.io);
        self.tmp.cleanup();
    }
};

test "phrase query matches only documents with adjacent terms" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // doc 1: phrase terms adjacent. doc 2: same terms present but NOT in
    // phrase order/adjacency — a bag-of-words (OR) search cannot tell these
    // apart; only real positional gating can.
    try h.facade.indexDocument(1, "the quick brown fox jumps high");
    try h.facade.indexDocument(2, "brown quick fox runs");
    // Flush so the manifest's total_docs/avg_doc_len are populated — BM25
    // scores are 0 for memtable-only docs before the first flush (the lib's
    // documented "no evidence to rank on yet" default).
    try h.facade.flush();

    // Sanity: plain OR search finds BOTH docs for the same terms.
    {
        const hits = try h.facade.search("quick brown fox", 0);
        defer alloc.free(hits);
        try testing.expectEqual(@as(usize, 2), hits.len);
    }

    // Phrase search finds ONLY the adjacent-term doc.
    {
        const hits = try h.facade.phraseSearch("quick brown fox", 0);
        defer alloc.free(hits);
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expectEqual(@as(u64, 1), hits[0].doc_id);
        try testing.expect(hits[0].score > 0);
    }

    // A phrase present in neither doc matches nothing.
    {
        const hits = try h.facade.phraseSearch("fox quick", 0);
        defer alloc.free(hits);
        try testing.expectEqual(@as(usize, 0), hits.len);
    }
}

test "phrase query honors stopword ordinal gaps on both sides" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // "and" is a stopword: it is never indexed but DOES consume ordinal 1, so
    // the indexed positions are quick@0, brown@2.
    try h.facade.indexDocument(10, "quick and brown");

    // The query "quick and brown" tokenizes to the same gapped ordinals
    // (quick@0, brown@2) — it must match.
    {
        const hits = try h.facade.phraseSearch("quick and brown", 0);
        defer alloc.free(hits);
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expectEqual(@as(u64, 10), hits[0].doc_id);
    }

    // The query "quick brown" expects ADJACENT ordinals (delta 1) — the
    // stopword gap in the document (delta 2) must NOT match. This pins the
    // real positional semantics: a substring/bag-of-words fake would pass.
    {
        const hits = try h.facade.phraseSearch("quick brown", 0);
        defer alloc.free(hits);
        try testing.expectEqual(@as(usize, 0), hits.len);
    }
}

test "proximity query honors the token window" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // Tokens: geode@0 supports@1 fast@2 positional@3 queries@4.
    try h.facade.indexDocument(20, "geode supports fast positional queries");

    // span(geode, queries) == 4: matches at distance 4 ...
    {
        const hits = try h.facade.proximitySearch("geode queries", 4, 0);
        defer alloc.free(hits);
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expectEqual(@as(u64, 20), hits[0].doc_id);
    }
    // ... but NOT at distance 3.
    {
        const hits = try h.facade.proximitySearch("geode queries", 3, 0);
        defer alloc.free(hits);
        try testing.expectEqual(@as(usize, 0), hits.len);
    }
    // Order-insensitive NEAR: reversed query order still matches.
    {
        const hits = try h.facade.proximitySearch("queries geode", 4, 0);
        defer alloc.free(hits);
        try testing.expectEqual(@as(usize, 1), hits.len);
    }
    // A term absent from the document never matches regardless of window.
    {
        const hits = try h.facade.proximitySearch("geode elephant", 100, 0);
        defer alloc.free(hits);
        try testing.expectEqual(@as(usize, 0), hits.len);
    }
}

test "proximity query requires at least two distinct terms" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.facade.indexDocument(30, "geode supports proximity");

    try testing.expectError(error.TooFewTerms, h.facade.proximitySearch("geode", 5, 0));
    // Duplicate occurrences of ONE term are still one distinct term.
    try testing.expectError(error.TooFewTerms, h.facade.proximitySearch("geode geode", 5, 0));
}

test "highlight returns byte-accurate offsets against the real stored text" {
    const alloc = testing.allocator;

    // Highlight runs on caller-supplied AUTHORIZED content (post-RLS/FLE) —
    // it is a pure content -> offsets mapping using the index-time tokenizer.
    //
    // Case folding uses the SAME index-time pipeline (geode_unicode.foldCase,
    // a documented minimal subset — see tests/test_fts_tokenizer.zig Case 3),
    // so we exercise the fold with a letter it DOES fold ('E' -> 'e').
    const content = "Example content for geode fts highlighting";

    const frags = try FullTextIndex.highlight(alloc, content, "example fts");
    defer alloc.free(frags);

    try testing.expectEqual(@as(usize, 2), frags.len);

    // Offsets must point at the REAL raw bytes ("Example", "fts") — matching
    // is pipeline-folded but the highlight range covers the original text.
    const example_off = std.mem.indexOf(u8, content, "Example").?;
    const fts_off = std.mem.indexOf(u8, content, "fts").?;

    try testing.expectEqual(example_off, frags[0].offset);
    try testing.expectEqual(@as(usize, "Example".len), frags[0].length);
    try testing.expectEqualStrings("Example", frags[0].term);
    try testing.expectEqualStrings("Example", content[frags[0].offset .. frags[0].offset + frags[0].length]);

    try testing.expectEqual(fts_off, frags[1].offset);
    try testing.expectEqual(@as(usize, "fts".len), frags[1].length);
    try testing.expectEqualStrings("fts", frags[1].term);

    // Stopwords ("for") are never highlighted even when queried.
    const stop = try FullTextIndex.highlight(alloc, content, "for");
    defer alloc.free(stop);
    try testing.expectEqual(@as(usize, 0), stop.len);

    // No-match query highlights nothing.
    const none = try FullTextIndex.highlight(alloc, content, "elephant");
    defer alloc.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "phrase and proximity survive a flush to durable segments" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.facade.indexDocument(40, "alpha beta gamma delta");
    // Force the memtable into an on-disk segment, then verify the positional
    // queries read positions back out of the persisted postings.
    try h.facade.flush();

    {
        const hits = try h.facade.phraseSearch("beta gamma", 0);
        defer alloc.free(hits);
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expectEqual(@as(u64, 40), hits[0].doc_id);
    }
    {
        const hits = try h.facade.proximitySearch("alpha delta", 3, 0);
        defer alloc.free(hits);
        try testing.expectEqual(@as(usize, 1), hits.len);
    }
    {
        const hits = try h.facade.proximitySearch("alpha delta", 2, 0);
        defer alloc.free(hits);
        try testing.expectEqual(@as(usize, 0), hits.len);
    }
}
