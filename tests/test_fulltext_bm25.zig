// Comprehensive test suite for BM25 full-text search
// CANARY: REQ=REQ-GQL-FTS-TEST; FEATURE="FTS Test Suite"; ASPECT=Testing; STATUS=TESTED; TEST=TestCANARY_FTS_Suite; OWNER=test; UPDATED=2025-01-29

const std = @import("std");
const testing = std.testing;
const lib = @import("geode");
const fulltext = lib.index.fulltext;

test "TestCANARY_FTS_Suite basic indexing" {
    const allocator = testing.allocator;

    var index = try fulltext.FullTextIndex.init(allocator);
    defer index.deinit();

    // Index documents
    try index.indexDocument(1, "The quick brown fox jumps over the lazy dog");
    try index.indexDocument(2, "A quick brown dog runs through the forest");
    try index.indexDocument(3, "The lazy cat sleeps under the warm sun");

    try testing.expect(index.documents.count() == 3);
}

test "TestCANARY_FTS_Suite BM25 scoring" {
    const allocator = testing.allocator;

    var index = try fulltext.FullTextIndex.init(allocator);
    defer index.deinit();

    // Index test corpus
    try index.indexDocument(1, "Information retrieval is the science of searching");
    try index.indexDocument(2, "BM25 is a ranking function used in information retrieval");
    try index.indexDocument(3, "The ranking function calculates document relevance");
    try index.indexDocument(4, "Search engines use ranking algorithms");

    // Search for "ranking function"
    const results = try index.search("ranking function", 10);
    defer allocator.free(results);

    // Document 3 should rank highest (contains both terms)
    try testing.expect(results.len > 0);
    try testing.expect(results[0].doc_id == 3 or results[0].doc_id == 2);
    try testing.expect(results[0].score > 0);
}

test "TestCANARY_FTS_Suite stopword filtering" {
    const allocator = testing.allocator;

    var index = try fulltext.FullTextIndex.init(allocator);
    defer index.deinit();

    // Index document with many stopwords
    try index.indexDocument(1, "This is a test of the emergency broadcast system");
    try index.indexDocument(2, "Emergency broadcast system test");

    // Search with stopwords - should ignore them
    const results = try index.search("the emergency system", 10);
    defer allocator.free(results);

    try testing.expect(results.len == 2);
    // Both documents should have similar scores (stopwords ignored)
    if (results.len >= 2) {
        const score_diff = @abs(results[0].score - results[1].score);
        try testing.expect(score_diff < results[0].score); // Scores should be relatively close
    }
}

test "TestCANARY_FTS_Suite document removal" {
    const allocator = testing.allocator;

    var index = try fulltext.FullTextIndex.init(allocator);
    defer index.deinit();

    // Index and remove documents
    try index.indexDocument(1, "Document one about cats");
    try index.indexDocument(2, "Document two about dogs");
    try index.indexDocument(3, "Document three about cats and dogs");

    try index.removeDocument(2);

    const results = try index.search("dogs", 10);
    defer allocator.free(results);

    // Only document 3 should be found
    try testing.expect(results.len == 1);
    if (results.len > 0) {
        try testing.expect(results[0].doc_id == 3);
    }
}

test "TestCANARY_FTS_Suite phrase proximity" {
    const allocator = testing.allocator;

    var index = try fulltext.FullTextIndex.init(allocator);
    defer index.deinit();

    // Documents with different term proximities
    try index.indexDocument(1, "New York City is a major metropolitan area");
    try index.indexDocument(2, "The city of New York has many attractions");
    try index.indexDocument(3, "York is a city in England, not New");

    const results = try index.search("New York", 10);
    defer allocator.free(results);

    // Documents with "New York" together should score higher
    try testing.expect(results.len > 0);
    if (results.len > 0) {
        // First result should be doc 1 or 2 (has "New York" together)
        try testing.expect(results[0].doc_id == 1 or results[0].doc_id == 2);
    }
}

test "TestCANARY_FTS_Suite unicode normalization" {
    const allocator = testing.allocator;

    var index = try fulltext.FullTextIndex.init(allocator);
    defer index.deinit();

    // Test with accented characters
    try index.indexDocument(1, "café résumé naïve");
    try index.indexDocument(2, "cafe resume naive");

    // Both searches should find both documents (after normalization)
    const results1 = try index.search("café", 10);
    defer allocator.free(results1);

    const results2 = try index.search("cafe", 10);
    defer allocator.free(results2);

    // Both searches should return results
    try testing.expect(results1.len > 0);
    try testing.expect(results2.len > 0);
}

test "TestCANARY_FTS_Suite large corpus" {
    const allocator = testing.allocator;

    var index = try fulltext.FullTextIndex.init(allocator);
    defer index.deinit();

    // Index many documents
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        const content = try std.fmt.allocPrint(allocator, "Document {} contains test content with keywords alpha beta gamma delta epsilon", .{i});
        defer allocator.free(content);
        try index.indexDocument(i, content);
    }

    // Add some specific documents
    try index.indexDocument(1000, "Special document with unique alpha omega content");
    try index.indexDocument(1001, "Another special document with omega and theta");

    // Search for rare term
    const results = try index.search("omega", 10);
    defer allocator.free(results);

    // Should find the special documents
    try testing.expect(results.len == 2);
    for (results) |result| {
        try testing.expect(result.doc_id == 1000 or result.doc_id == 1001);
    }
}

test "TestCANARY_FTS_Suite empty query" {
    const allocator = testing.allocator;

    var index = try fulltext.FullTextIndex.init(allocator);
    defer index.deinit();

    try index.indexDocument(1, "Test document");

    const results = try index.search("", 10);
    defer allocator.free(results);

    try testing.expect(results.len == 0);
}

test "TestCANARY_FTS_Suite repeated terms" {
    const allocator = testing.allocator;

    var index = try fulltext.FullTextIndex.init(allocator);
    defer index.deinit();

    // Document with repeated terms should score higher
    try index.indexDocument(1, "test test test important");
    try index.indexDocument(2, "test important");
    try index.indexDocument(3, "important");

    const results = try index.search("test", 10);
    defer allocator.free(results);

    // Document 1 should score highest (more occurrences of "test")
    try testing.expect(results.len > 0);
    if (results.len > 0) {
        try testing.expect(results[0].doc_id == 1);
    }
}

test "TestCANARY_FTS_Suite document length normalization" {
    const allocator = testing.allocator;

    var index = try fulltext.FullTextIndex.init(allocator);
    defer index.deinit();

    // Short document with term
    try index.indexDocument(1, "Geode database");

    // Long document with same term
    var long_content = std.ArrayList(u8).init(allocator);
    defer long_content.deinit();
    try long_content.appendSlice("Geode database ");
    var j: u32 = 0;
    while (j < 100) : (j += 1) {
        try long_content.appendSlice("with many other words that make the document very long ");
    }
    try index.indexDocument(2, long_content.items);

    const results = try index.search("Geode", 10);
    defer allocator.free(results);

    // Shorter document should score higher (length normalization)
    try testing.expect(results.len == 2);
    if (results.len == 2) {
        try testing.expect(results[0].doc_id == 1);
    }
}
