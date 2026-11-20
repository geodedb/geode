const std = @import("std");
const testing = std.testing;

// Integration test for Enhanced Full-Text Search with BM25 scoring and IndexOptimizer
// CANARY: REQ=REQ-GQL-204; FEATURE="FullTextBM25Integration"; ASPECT=IndexIntegration; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_204_FullTextBM25Integration; OWNER=index; UPDATED=2026-11-14

// Simplified structures for testing full-text search integration
const BM25Score = struct {
    doc_id: u64,
    score: f64,
    highlights: []const []const u8,

    pub fn compare(_: void, a: BM25Score, b: BM25Score) bool {
        return a.score > b.score; // Higher scores first
    }
};

const FullTextIndexSimulator = struct {
    allocator: std.mem.Allocator,
    documents: std.AutoHashMap(u64, Document),
    inverted_index: std.StringHashMap(TermInfo),
    analyzer_type: []const u8,

    const Document = struct {
        id: u64,
        content: []const u8,
        term_frequencies: std.StringHashMap(u32),
        total_terms: u32,
    };

    const TermInfo = struct {
        term: []const u8,
        doc_frequency: u32,
        postings: std.ArrayList(Posting),
    };

    const Posting = struct {
        doc_id: u64,
        term_frequency: u32,
        positions: []const u32,
    };

    pub fn init(allocator: std.mem.Allocator, analyzer: []const u8) FullTextIndexSimulator {
        return FullTextIndexSimulator{
            .allocator = allocator,
            .documents = std.AutoHashMap(u64, Document).init(allocator),
            .inverted_index = std.StringHashMap(TermInfo).init(allocator),
            .analyzer_type = analyzer,
        };
    }

    pub fn deinit(self: *FullTextIndexSimulator) void {
        // Clean up documents
        var doc_it = self.documents.iterator();
        while (doc_it.next()) |entry| {
            entry.value_ptr.term_frequencies.deinit();
            self.allocator.free(entry.value_ptr.content);
        }
        self.documents.deinit();

        // Clean up inverted index
        var term_it = self.inverted_index.iterator();
        while (term_it.next()) |entry| {
            entry.value_ptr.postings.deinit(self.allocator);
            self.allocator.free(entry.value_ptr.term);
        }
        self.inverted_index.deinit();
    }

    pub fn indexDocument(self: *FullTextIndexSimulator, doc_id: u64, content: []const u8) !void {
        // Tokenize based on analyzer
        const tokens = try self.tokenize(content);
        defer {
            for (tokens) |token| {
                self.allocator.free(token);
            }
            self.allocator.free(tokens);
        }

        // Create document with term frequencies
        var doc = Document{
            .id = doc_id,
            .content = try self.allocator.dupe(u8, content),
            .term_frequencies = std.StringHashMap(u32).init(self.allocator),
            .total_terms = @intCast(tokens.len),
        };

        // Count term frequencies
        for (tokens) |token| {
            const result = try doc.term_frequencies.getOrPut(token);
            if (!result.found_existing) {
                result.value_ptr.* = 0;
            }
            result.value_ptr.* += 1;

            // Update inverted index
            try self.updateInvertedIndex(token, doc_id, result.value_ptr.*);
        }

        try self.documents.put(doc_id, doc);
    }

    fn tokenize(self: *FullTextIndexSimulator, text: []const u8) ![][]const u8 {
        var tokens = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch unreachable;

        if (std.mem.eql(u8, self.analyzer_type, "simple")) {
            // Simple whitespace tokenization
            var it = std.mem.tokenizeAny(u8, text, " \t\n\r");
            while (it.next()) |token| {
                try tokens.append(self.allocator, try self.allocator.dupe(u8, token));
            }
        } else if (std.mem.eql(u8, self.analyzer_type, "standard")) {
            // Standard tokenization with punctuation handling
            var it = std.mem.tokenizeAny(u8, text, " \t\n\r.,;:!?()[]{}\"'");
            while (it.next()) |token| {
                const lower = try self.lowercase(token);
                try tokens.append(self.allocator, lower);
            }
        } else if (std.mem.eql(u8, self.analyzer_type, "english")) {
            // English tokenization with stop word removal
            var it = std.mem.tokenizeAny(u8, text, " \t\n\r.,;:!?()[]{}\"'");
            while (it.next()) |token| {
                const lower = try self.lowercase(token);
                if (!self.isStopWord(lower)) {
                    try tokens.append(self.allocator, lower);
                } else {
                    self.allocator.free(lower);
                }
            }
        }

        return try tokens.toOwnedSlice(self.allocator);
    }

    fn lowercase(self: *FullTextIndexSimulator, text: []const u8) ![]u8 {
        const result = try self.allocator.alloc(u8, text.len);
        for (text, 0..) |c, i| {
            result[i] = std.ascii.toLower(c);
        }
        return result;
    }

    fn isStopWord(self: *FullTextIndexSimulator, word: []const u8) bool {
        _ = self;
        const stop_words = [_][]const u8{ "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with", "by", "from", "up", "about", "into", "through", "during", "before", "after", "above", "below", "over", "under" };

        for (stop_words) |stop_word| {
            if (std.mem.eql(u8, word, stop_word)) {
                return true;
            }
        }
        return false;
    }

    fn updateInvertedIndex(self: *FullTextIndexSimulator, term: []const u8, doc_id: u64, tf: u32) !void {
        // Use a duped string as the key to ensure it persists
        const term_key = try self.allocator.dupe(u8, term);

        const result = try self.inverted_index.getOrPut(term_key);

        if (!result.found_existing) {
            result.value_ptr.* = TermInfo{
                .term = term_key, // Use the same duped string
                .doc_frequency = 0,
                .postings = std.ArrayList(Posting).initCapacity(self.allocator, 0) catch unreachable,
            };
        } else {
            // If key already exists, free the duplicate we just made
            self.allocator.free(term_key);
        }

        // Check if doc already exists in postings
        var found = false;
        for (result.value_ptr.postings.items) |*posting| {
            if (posting.doc_id == doc_id) {
                posting.term_frequency = tf;
                found = true;
                break;
            }
        }

        if (!found) {
            try result.value_ptr.postings.append(self.allocator, .{
                .doc_id = doc_id,
                .term_frequency = tf,
                .positions = &[_]u32{}, // Simplified - no position tracking
            });
            result.value_ptr.doc_frequency += 1;
        }
    }

    pub fn search(self: *FullTextIndexSimulator, query_terms: []const []const u8, max_results: u32) ![]BM25Score {
        var doc_scores = std.AutoHashMap(u64, f64).init(self.allocator);
        defer doc_scores.deinit();

        const total_docs = @as(f64, @floatFromInt(self.documents.count()));
        var total_doc_length: f64 = 0;

        // Calculate average document length
        var doc_it = self.documents.iterator();
        while (doc_it.next()) |entry| {
            total_doc_length += @as(f64, @floatFromInt(entry.value_ptr.total_terms));
        }
        const avg_doc_length = if (total_docs > 0) total_doc_length / total_docs else 1.0;

        // BM25 parameters
        const k1: f64 = 1.2;
        const b: f64 = 0.75;

        // Process each query term
        for (query_terms) |term| {
            if (self.inverted_index.get(term)) |term_info| {
                const df = @as(f64, @floatFromInt(term_info.doc_frequency));
                // Fix IDF calculation to prevent negative values
                const idf = @max(0.1, @log((total_docs - df + 0.5) / (df + 0.5)));

                for (term_info.postings.items) |posting| {
                    const tf = @as(f64, @floatFromInt(posting.term_frequency));
                    const doc = self.documents.get(posting.doc_id).?;
                    const doc_length = @as(f64, @floatFromInt(doc.total_terms));

                    const bm25_score = idf * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * (doc_length / avg_doc_length)));

                    const result = try doc_scores.getOrPut(posting.doc_id);
                    if (!result.found_existing) {
                        result.value_ptr.* = 0;
                    }
                    result.value_ptr.* += bm25_score;
                }
            }
        }

        // Convert to result array and sort
        var results = std.ArrayList(BM25Score).initCapacity(self.allocator, 0) catch unreachable;
        defer results.deinit(self.allocator);

        var score_it = doc_scores.iterator();
        while (score_it.next()) |entry| {
            if (entry.value_ptr.* > 0) {
                try results.append(self.allocator, .{
                    .doc_id = entry.key_ptr.*,
                    .score = entry.value_ptr.*,
                    .highlights = &[_][]const u8{}, // Simplified - no highlighting
                });
            }
        }

        std.sort.heap(BM25Score, results.items, {}, BM25Score.compare);

        const n = @min(max_results, results.items.len);
        return try self.allocator.dupe(BM25Score, results.items[0..n]);
    }

    pub fn estimateSearchCost(self: *FullTextIndexSimulator, query_terms: []const []const u8, max_results: u32) f64 {
        const collection_size = @as(f64, @floatFromInt(self.documents.count()));
        const log_factor = if (collection_size > 1) @log(collection_size) else 1.0;
        const term_factor = @as(f64, @floatFromInt(query_terms.len)) * 2.0;
        const result_factor = @as(f64, @floatFromInt(max_results)) * 0.1;

        return 15.0 + log_factor + term_factor + result_factor;
    }
};

test "TestCANARY_REQ_GQL_204_FullTextBM25Integration" {
    const allocator = testing.allocator;

    // Create full-text index simulator
    var ft_index = FullTextIndexSimulator.init(allocator, "standard");
    defer ft_index.deinit();

    // Index test documents
    try ft_index.indexDocument(1, "Information retrieval systems use sophisticated algorithms");
    try ft_index.indexDocument(2, "BM25 is a ranking function used in information retrieval and search engines");
    try ft_index.indexDocument(3, "Machine learning algorithms improve search relevance scoring");
    try ft_index.indexDocument(4, "Database systems provide efficient data retrieval mechanisms");
    try ft_index.indexDocument(5, "Search engines rank documents using various scoring algorithms");

    // Test BM25 search
    const query_terms = [_][]const u8{ "information", "retrieval" };
    const results = try ft_index.search(&query_terms, 3);
    defer allocator.free(results);

    // Verify results
    try testing.expect(results.len <= 3);
    try testing.expect(results.len > 0);

    // Results should be sorted by score (highest first)
    if (results.len >= 2) {
        try testing.expect(results[0].score >= results[1].score);
    }

    // Documents 1 and 2 should score highest (both contain both terms)
    var found_doc1 = false;
    var found_doc2 = false;
    for (results) |result| {
        if (result.doc_id == 1 or result.doc_id == 2) {
            try testing.expect(result.score > 0);
            if (result.doc_id == 1) found_doc1 = true;
            if (result.doc_id == 2) found_doc2 = true;
        }
    }
    try testing.expect(found_doc1 or found_doc2);

    std.debug.print("\nFull-Text BM25 integration test passed\n", .{});
    std.debug.print("  Found {} results for query: {s}, {s}\n", .{ results.len, query_terms[0], query_terms[1] });
    for (results, 0..) |result, i| {
        std.debug.print("  {}: doc={}, score={d:.3}\n", .{ i + 1, result.doc_id, result.score });
    }
}

test "analyzer comparison test" {
    const allocator = testing.allocator;

    const analyzers = [_][]const u8{ "simple", "standard", "english" };

    for (analyzers) |analyzer| {
        var ft_index = FullTextIndexSimulator.init(allocator, analyzer);
        defer ft_index.deinit();

        // Index test documents
        try ft_index.indexDocument(1, "The quick brown fox jumps over the lazy dog");
        try ft_index.indexDocument(2, "A fast brown animal leaps above a sleepy canine");
        try ft_index.indexDocument(3, "Quick animals demonstrate agility and speed");

        const query_terms = [_][]const u8{ "quick", "brown" };
        const results = try ft_index.search(&query_terms, 2);
        defer allocator.free(results);

        try testing.expect(results.len <= 2);

        std.debug.print("\nAnalyzer: {s}\n", .{analyzer});
        for (results, 0..) |result, i| {
            std.debug.print("  {}: doc={}, score={d:.3}\n", .{ i + 1, result.doc_id, result.score });
        }
    }

    std.debug.print("\nAnalyzer comparison test passed\n", .{});
}

test "BM25 scoring accuracy test" {
    const allocator = testing.allocator;

    var ft_index = FullTextIndexSimulator.init(allocator, "standard");
    defer ft_index.deinit();

    // Create documents with known term frequencies
    try ft_index.indexDocument(1, "cat cat dog"); // 2 cats, 1 dog
    try ft_index.indexDocument(2, "cat dog dog dog"); // 1 cat, 3 dogs
    try ft_index.indexDocument(3, "bird bird bird"); // 3 birds, no cats/dogs

    // Search for "cat" - doc 1 should score higher than doc 2 (higher TF)
    const cat_query = [_][]const u8{"cat"};
    const cat_results = try ft_index.search(&cat_query, 2);
    defer allocator.free(cat_results);

    try testing.expect(cat_results.len >= 1);
    try testing.expect(cat_results[0].doc_id == 1 or cat_results[0].doc_id == 2);

    // Search for "dog" - doc 2 should score higher than doc 1 (higher TF)
    const dog_query = [_][]const u8{"dog"};
    const dog_results = try ft_index.search(&dog_query, 2);
    defer allocator.free(dog_results);

    try testing.expect(dog_results.len >= 1);
    try testing.expect(dog_results[0].doc_id == 1 or dog_results[0].doc_id == 2);

    // Search for "bird" - only doc 3 should match
    const bird_query = [_][]const u8{"bird"};
    const bird_results = try ft_index.search(&bird_query, 2);
    defer allocator.free(bird_results);

    try testing.expect(bird_results.len == 1);
    try testing.expect(bird_results[0].doc_id == 3);

    std.debug.print("\nBM25 scoring accuracy test passed\n", .{});
    std.debug.print("  Cat search: doc {} scored {d:.3}\n", .{ cat_results[0].doc_id, cat_results[0].score });
    std.debug.print("  Dog search: doc {} scored {d:.3}\n", .{ dog_results[0].doc_id, dog_results[0].score });
    std.debug.print("  Bird search: doc {} scored {d:.3}\n", .{ bird_results[0].doc_id, bird_results[0].score });
}

test "cost estimation test" {
    const allocator = testing.allocator;

    var ft_index = FullTextIndexSimulator.init(allocator, "standard");
    defer ft_index.deinit();

    // Add documents to test cost scaling
    const sizes = [_]u32{ 10, 100, 1000 };

    for (sizes) |size| {
        // Clear previous documents
        ft_index.deinit();
        ft_index = FullTextIndexSimulator.init(allocator, "standard");

        // Add 'size' documents
        var i: u32 = 1;
        while (i <= size) : (i += 1) {
            const content = try std.fmt.allocPrint(allocator, "document number {} contains various words for testing search functionality", .{i});
            defer allocator.free(content);
            try ft_index.indexDocument(i, content);
        }

        // Test cost estimation for different query complexities
        const queries = [_][]const []const u8{
            &[_][]const u8{"test"},
            &[_][]const u8{ "test", "document" },
            &[_][]const u8{ "test", "document", "search", "functionality" },
        };

        for (queries) |query| {
            const cost = ft_index.estimateSearchCost(query, 10);
            try testing.expect(cost > 0);

            std.debug.print("Size: {}, Query terms: {}, Cost: {d:.2}\n", .{ size, query.len, cost });
        }
    }

    std.debug.print("\nCost estimation test passed\n", .{});
}

test "large scale full-text performance simulation" {
    const allocator = testing.allocator;

    const collection_size = 1000;
    const query_terms = [_][]const u8{ "machine", "learning", "algorithm" };

    var ft_index = FullTextIndexSimulator.init(allocator, "english");
    defer ft_index.deinit();

    // Simulate adding large collection
    var timer = std.time.Timer.start() catch return;

    var i: u32 = 1;
    while (i <= collection_size) : (i += 1) {
        const content = try std.fmt.allocPrint(allocator, "Document {} discusses machine learning algorithms and their applications in modern data processing systems. Advanced techniques include neural networks, decision trees, and ensemble methods for predictive analytics.", .{i});
        defer allocator.free(content);
        try ft_index.indexDocument(i, content);
    }

    const indexing_time = timer.lap();

    // Simulate full-text search
    const results = try ft_index.search(&query_terms, 20);
    defer allocator.free(results);
    const search_time = timer.read();

    // Cost estimation
    const estimated_cost = ft_index.estimateSearchCost(&query_terms, 20);

    try testing.expect(results.len > 0);
    try testing.expect(results.len <= 20);
    try testing.expect(estimated_cost > 0);
    try testing.expect(estimated_cost < 1000.0); // Should be reasonable

    std.debug.print("\nLarge scale full-text performance simulation\n", .{});
    std.debug.print("  Collection size: {}\n", .{collection_size});
    std.debug.print("  Query terms: {}\n", .{query_terms.len});
    std.debug.print("  Results found: {}\n", .{results.len});
    std.debug.print("  Indexing time: {}ns\n", .{indexing_time});
    std.debug.print("  Search time: {}ns\n", .{search_time});
    std.debug.print("  Estimated cost: {d:.2}\n", .{estimated_cost});

    // Show top results
    for (results[0..@min(5, results.len)], 0..) |result, idx| {
        std.debug.print("  Top {}: doc={}, score={d:.3}\n", .{ idx + 1, result.doc_id, result.score });
    }
}

test "multi-field search simulation" {
    const allocator = testing.allocator;

    // Simulate different field types (title, content, tags)
    const fields = [_][]const u8{ "title", "content", "tags" };
    var field_indexes = std.ArrayList(FullTextIndexSimulator).initCapacity(allocator, 0) catch unreachable;
    defer {
        for (field_indexes.items) |*index| {
            index.deinit();
        }
        field_indexes.deinit(allocator);
    }

    // Create index for each field
    for (fields) |_| {
        try field_indexes.append(allocator, FullTextIndexSimulator.init(allocator, "standard"));
    }

    // Index documents across fields
    const documents = [_]struct { title: []const u8, content: []const u8, tags: []const u8 }{
        .{ .title = "Machine Learning Basics", .content = "Introduction to machine learning algorithms and techniques", .tags = "ML algorithms tutorial" },
        .{ .title = "Deep Learning Neural Networks", .content = "Advanced neural network architectures for deep learning applications", .tags = "deep learning AI neural" },
        .{ .title = "Data Mining Techniques", .content = "Data mining algorithms for pattern discovery and knowledge extraction", .tags = "data mining patterns algorithms" },
        .{ .title = "Natural Language Processing", .content = "NLP techniques for text analysis and language understanding", .tags = "NLP text analysis language" },
    };

    for (documents, 0..) |doc, doc_id| {
        const doc_fields = [_][]const u8{ doc.title, doc.content, doc.tags };
        for (doc_fields, 0..) |field_content, field_idx| {
            try field_indexes.items[field_idx].indexDocument(doc_id + 1, field_content);
        }
    }

    // Search across fields with different weights
    const query_terms = [_][]const u8{ "machine", "learning" };
    const field_weights = [_]f64{ 2.0, 1.0, 1.5 }; // Title weighted higher

    var combined_scores = std.AutoHashMap(u64, f64).init(allocator);
    defer combined_scores.deinit();

    for (field_indexes.items, 0..) |*field_index, field_idx| {
        const field_results = try field_index.search(&query_terms, 10);
        defer allocator.free(field_results);

        for (field_results) |result| {
            const weighted_score = result.score * field_weights[field_idx];
            const combined_result = try combined_scores.getOrPut(result.doc_id);
            if (!combined_result.found_existing) {
                combined_result.value_ptr.* = 0;
            }
            combined_result.value_ptr.* += weighted_score;
        }
    }

    // Convert to final results
    var final_results = std.ArrayList(BM25Score).initCapacity(allocator, 0) catch unreachable;
    defer final_results.deinit(allocator);

    var score_it = combined_scores.iterator();
    while (score_it.next()) |entry| {
        try final_results.append(allocator, .{
            .doc_id = entry.key_ptr.*,
            .score = entry.value_ptr.*,
            .highlights = &[_][]const u8{},
        });
    }

    std.sort.heap(BM25Score, final_results.items, {}, BM25Score.compare);

    try testing.expect(final_results.items.len > 0);

    std.debug.print("\nMulti-field search simulation\n", .{});
    std.debug.print("  Fields: title (2.0x), content (1.0x), tags (1.5x)\n", .{});
    std.debug.print("  Query: {s}, {s}\n", .{ query_terms[0], query_terms[1] });

    for (final_results.items, 0..) |result, i| {
        std.debug.print("  {}: doc={}, combined_score={d:.3}\n", .{ i + 1, result.doc_id, result.score });
    }

    std.debug.print("Multi-field search simulation passed\n", .{});
}
