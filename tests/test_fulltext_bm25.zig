// Comprehensive test suite for BM25 full-text search — adapter-backed facade.
//
// After the fts-storage migration, `FullTextIndex` is a thin facade over the
// external fts-storage LSM engine via `FtsStorageAdapter`. It no longer has a
// standalone in-memory `init`/`documents`; the owner creates the adapter + a
// named index, then constructs the facade with `initBacked`. These tests build
// a TmpDir-backed adapter, create the "default" index, wrap it in the facade,
// index docs, flush, and search — all under `std.testing.allocator` so the
// end-of-test leak check guards every allocation (notably the per-term `[]Hit`
// slices that `search` must free — see the C1 leak-guard test at the bottom).
//
// CANARY: REQ=REQ-GQL-FTS-TEST; FEATURE="FTS Test Suite"; ASPECT=Testing; STATUS=TESTED; TEST=TestCANARY_FTS_Suite; OWNER=test; UPDATED=2026-05-30

const std = @import("std");
const testing = std.testing;
const lib = @import("geode");
const fulltext = lib.index.fulltext;
const adapter_mod = lib.index.fts_storage_adapter;
const FtsStorageAdapter = adapter_mod.FtsStorageAdapter;

// TmpDir-backed adapter + facade harness. Mirrors the proven setup in
// tests/test_fts_storage_adapter.zig: `std.testing.tmpDir` yields a TmpDir whose
// `.dir` is a `std.Io.Dir` built with the process-global single-threaded io —
// the same world the adapter speaks — so we borrow that global io and open the
// `fts` base_dir RELATIVE to `tmp.dir`. The adapter stores `base_path` ("fts")
// for diagnostics only; all child I/O is base_dir-relative.
//
// Heap-allocated so `index` (which borrows the adapter pointer) and the adapter
// itself have stable addresses. Caller frees via `deinit` + `allocator.destroy`.
const Harness = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    adapter: *FtsStorageAdapter,
    index: fulltext.FullTextIndex,
    tmp: testing.TmpDir,
    base_dir: std.Io.Dir,

    fn deinit(self: *Harness) void {
        // Order mirrors the per-graph owner (ManagedGraph): flush → facade
        // deinit (frees the owned index-name dupe) → adapter deinit → close
        // base_dir → clean tmp. The adapter does NOT close base_dir.
        self.index.flush() catch {};
        self.index.deinit();
        self.adapter.deinit();
        self.base_dir.close(self.io);
        self.tmp.cleanup();
    }
};

fn makeHarness(allocator: std.mem.Allocator) !*Harness {
    const h = try allocator.create(Harness);
    errdefer allocator.destroy(h);

    var tmp = testing.tmpDir(.{});
    errdefer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const base_dir = try tmp.dir.createDirPathOpen(io, "fts", .{});

    const adapter = try FtsStorageAdapter.init(allocator, io, base_dir, "fts");
    errdefer adapter.deinit();

    try adapter.createIndex("default");

    h.allocator = allocator;
    h.io = io;
    h.adapter = adapter;
    h.index = try fulltext.FullTextIndex.initBacked(allocator, adapter, "default");
    h.tmp = tmp;
    h.base_dir = base_dir;
    return h;
}

test "TestCANARY_FTS_Suite basic indexing + search" {
    const allocator = testing.allocator;
    var h = try makeHarness(allocator);
    defer {
        h.deinit();
        allocator.destroy(h);
    }

    try h.index.indexDocument(1, "The quick brown fox jumps over the lazy dog");
    try h.index.indexDocument(2, "A quick brown dog runs through the forest");
    try h.index.indexDocument(3, "The lazy cat sleeps under the warm sun");
    try h.index.flush();

    // "quick" appears in docs 1 and 2.
    const results = try h.index.search("quick", 10);
    defer allocator.free(results);
    try testing.expectEqual(@as(usize, 2), results.len);
    for (results) |r| try testing.expect(r.doc_id == 1 or r.doc_id == 2);
}

test "TestCANARY_FTS_Suite BM25 scoring" {
    const allocator = testing.allocator;
    var h = try makeHarness(allocator);
    defer {
        h.deinit();
        allocator.destroy(h);
    }

    try h.index.indexDocument(1, "Information retrieval is the science of searching");
    try h.index.indexDocument(2, "BM25 is a ranking function used in information retrieval");
    try h.index.indexDocument(3, "The ranking function calculates document relevance");
    try h.index.indexDocument(4, "Search engines use ranking algorithms");
    try h.index.flush();

    // Multi-term OR query; docs containing both "ranking" and "function"
    // (2 and 3) should outrank single-term matches.
    const results = try h.index.search("ranking function", 10);
    defer allocator.free(results);

    try testing.expect(results.len > 0);
    try testing.expect(results[0].doc_id == 3 or results[0].doc_id == 2);
    try testing.expect(results[0].score > 0);
}

test "TestCANARY_FTS_Suite stopword filtering" {
    const allocator = testing.allocator;
    var h = try makeHarness(allocator);
    defer {
        h.deinit();
        allocator.destroy(h);
    }

    try h.index.indexDocument(1, "This is a test of the emergency broadcast system");
    try h.index.indexDocument(2, "Emergency broadcast system test");
    try h.index.flush();

    // Stopwords ("the", "of") are dropped by the tokenizer, so the meaningful
    // terms still match both docs.
    const results = try h.index.search("the emergency system", 10);
    defer allocator.free(results);
    try testing.expectEqual(@as(usize, 2), results.len);
}

test "TestCANARY_FTS_Suite document removal" {
    const allocator = testing.allocator;
    var h = try makeHarness(allocator);
    defer {
        h.deinit();
        allocator.destroy(h);
    }

    try h.index.indexDocument(1, "Document one about cats");
    try h.index.indexDocument(2, "Document two about dogs");
    try h.index.indexDocument(3, "Document three about cats and dogs");
    try h.index.flush();

    try h.index.removeDocument(2);
    try h.index.flush();

    const results = try h.index.search("dogs", 10);
    defer allocator.free(results);

    // Only document 3 should remain for "dogs".
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqual(@as(u64, 3), results[0].doc_id);
}

test "TestCANARY_FTS_Suite unicode normalization" {
    const allocator = testing.allocator;
    var h = try makeHarness(allocator);
    defer {
        h.deinit();
        allocator.destroy(h);
    }

    try h.index.indexDocument(1, "café résumé naïve");
    try h.index.indexDocument(2, "cafe resume naive");
    try h.index.flush();

    // After NFC + casefold normalization both forms should match each other.
    const results1 = try h.index.search("café", 10);
    defer allocator.free(results1);
    const results2 = try h.index.search("cafe", 10);
    defer allocator.free(results2);

    try testing.expect(results1.len > 0);
    try testing.expect(results2.len > 0);
}

test "TestCANARY_FTS_Suite large corpus rare term" {
    const allocator = testing.allocator;
    var h = try makeHarness(allocator);
    defer {
        h.deinit();
        allocator.destroy(h);
    }

    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        const content = try std.fmt.allocPrint(allocator, "Document {} contains test content with keywords alpha beta gamma delta epsilon", .{i});
        defer allocator.free(content);
        try h.index.indexDocument(i, content);
    }
    try h.index.indexDocument(1000, "Special document with unique alpha omega content");
    try h.index.indexDocument(1001, "Another special document with omega and theta");
    try h.index.flush();

    const results = try h.index.search("omega", 10);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 2), results.len);
    for (results) |result| {
        try testing.expect(result.doc_id == 1000 or result.doc_id == 1001);
    }
}

test "TestCANARY_FTS_Suite empty query" {
    const allocator = testing.allocator;
    var h = try makeHarness(allocator);
    defer {
        h.deinit();
        allocator.destroy(h);
    }

    try h.index.indexDocument(1, "Test document");
    try h.index.flush();

    // An all-stopword/empty tokenization yields no query terms → no results,
    // and no allocations to leak.
    const results = try h.index.search("", 10);
    defer allocator.free(results);
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "TestCANARY_FTS_Suite repeated terms score higher" {
    const allocator = testing.allocator;
    var h = try makeHarness(allocator);
    defer {
        h.deinit();
        allocator.destroy(h);
    }

    try h.index.indexDocument(1, "test test test important");
    try h.index.indexDocument(2, "test important");
    try h.index.indexDocument(3, "important");
    try h.index.flush();

    const results = try h.index.search("test", 10);
    defer allocator.free(results);

    // Higher term frequency → doc 1 ranks first.
    try testing.expect(results.len > 0);
    try testing.expectEqual(@as(u64, 1), results[0].doc_id);
}

// ---------------------------------------------------------------------------
// C1 leak guard: FullTextIndex.search must free the `[]Hit` slice each
// adapter.search returns. Before the fix, search() iterated `hits` to merge
// scores but never freed them, leaking ONE slice per UNIQUE query term. In
// production an arena masked this; under std.testing.allocator the end-of-test
// leak check catches it. This test deliberately runs a MULTI-term query
// ("hello world") so search() calls adapter.search for 2+ distinct terms —
// exactly the path that leaked. It fails (leak detected) without the
// `defer self.allocator.free(hits)` fix in search() and passes with it.
//
// CANARY: REQ=REQ-GQL-FTS-001; FEATURE="BM25 Full-Text Search"; ASPECT=FTS; STATUS=TESTED; TEST=TestCANARY_FTS_Suite_multiterm_no_leak; OWNER=index; UPDATED=2026-05-30
test "TestCANARY_FTS_Suite multi-term search frees per-term Hit slices (C1)" {
    const allocator = testing.allocator;
    var h = try makeHarness(allocator);
    defer {
        h.deinit();
        allocator.destroy(h);
    }

    // Two docs, each carrying multiple DISTINCT terms so the query below
    // tokenizes into 2+ unique terms that each hit the postings store.
    try h.index.indexDocument(10, "hello world wide");
    try h.index.indexDocument(20, "hello there friend");
    try h.index.flush();

    // "hello world" → 2 unique terms → 2 adapter.search calls, each returning
    // a heap `[]Hit` owned by testing.allocator. Both must be freed inside
    // search(); the returned slice is the only thing this test owns. The
    // testing.allocator leak check at end-of-test is the real assertion here.
    const results = try h.index.search("hello world", 10);
    defer allocator.free(results);

    // Both docs match "hello"; doc 10 also matches "world" → top summed score.
    try testing.expect(results.len >= 2);
    try testing.expectEqual(@as(u64, 10), results[0].doc_id);

    var saw_10 = false;
    var saw_20 = false;
    for (results) |r| {
        if (r.doc_id == 10) saw_10 = true;
        if (r.doc_id == 20) saw_20 = true;
    }
    try testing.expect(saw_10 and saw_20);
}
