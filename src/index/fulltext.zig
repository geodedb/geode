const std = @import("std");
const Allocator = std.mem.Allocator;

// Full-text search index implementation
pub const FullTextIndex = struct {
    allocator: Allocator,
    documents: std.AutoHashMap(u64, Document),
    inverted_index: std.StringHashMap(PostingList),
    stopwords: std.StringHashMap(void),

    pub const Document = struct {
        id: u64,
        content: []const u8,
        tokens: []Token,
        vector: ?[]f32,
    };

    pub const Token = struct {
        text: []const u8,
        position: usize,
        offset: usize,
        length: usize,
    };

    pub const PostingList = struct {
        term: []const u8,
        documents: []PostingEntry,
        idf: f32,
    };

    pub const PostingEntry = struct {
        doc_id: u64,
        positions: []usize,
        tf: f32,
        tf_idf: f32,
    };

    pub const SearchResult = struct {
        doc_id: u64,
        score: f32,
        highlights: []Highlight,
    };

    pub const Highlight = struct {
        offset: usize,
        length: usize,
        term: []const u8,
    };

    pub fn init(allocator: Allocator) !FullTextIndex {
        var index = FullTextIndex{
            .allocator = allocator,
            .documents = std.AutoHashMap(u64, Document).init(allocator),
            .inverted_index = std.StringHashMap(PostingList).init(allocator),
            .stopwords = std.StringHashMap(void).init(allocator),
        };

        // Initialize common English stopwords
        const stopwords = [_][]const u8{
            "a",    "an",  "and", "are", "as",   "at",   "be",  "by", "for",
            "from", "has", "he",  "in",  "is",   "it",   "its", "of", "on",
            "that", "the", "to",  "was", "will", "with",
        };

        for (stopwords) |word| {
            try index.stopwords.put(word, {});
        }

        return index;
    }

    pub fn deinit(self: *FullTextIndex) void {
        var doc_it = self.documents.iterator();
        while (doc_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.content);
            self.allocator.free(entry.value_ptr.tokens);
            if (entry.value_ptr.vector) |vec| {
                self.allocator.free(vec);
            }
        }
        self.documents.deinit();

        var idx_it = self.inverted_index.iterator();
        while (idx_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.term);
            for (entry.value_ptr.documents) |*doc| {
                self.allocator.free(doc.positions);
            }
            self.allocator.free(entry.value_ptr.documents);
        }
        self.inverted_index.deinit();
        self.stopwords.deinit();
    }

    // Search for documents matching a query with enhanced BM25 scoring
    // CANARY: REQ=REQ-GQL-FTS-001; FEATURE="BM25 Full-Text Search"; ASPECT=FTS; STATUS=TESTED; TEST=TestCANARY_BM25_Search; OWNER=index; UPDATED=2025-09-29
    pub fn search(self: *FullTextIndex, query: []const u8, max_results: usize) ![]SearchResult {
        const query_tokens = try self.tokenize(query);
        defer self.allocator.free(query_tokens);

        var scores = std.AutoHashMap(u64, f32).init(self.allocator);
        defer scores.deinit();

        // Enhanced BM25 parameters with saturation tuning
        const k1: f32 = 1.2; // Term frequency saturation parameter
        const b: f32 = 0.75; // Length normalization parameter
        const k3: f32 = 7.0; // Query term frequency saturation (for repeated query terms)

        const avg_doc_len = try self.getAverageDocumentLength();
        const total_docs = @as(f32, @floatFromInt(self.documents.count()));

        // Count query term frequencies for BM25F variant
        var query_term_freq = std.StringHashMap(f32).init(self.allocator);
        defer query_term_freq.deinit();

        for (query_tokens) |token| {
            if (self.stopwords.contains(token.text)) continue;
            const normalized = try self.normalize(token.text);
            defer self.allocator.free(normalized);

            const current = query_term_freq.get(normalized) orelse 0;
            try query_term_freq.put(normalized, current + 1.0);
        }

        // Calculate scores with query term frequency consideration
        var it = query_term_freq.iterator();
        while (it.next()) |entry| {
            const term = entry.key_ptr.*;
            const qtf = entry.value_ptr.*;

            if (self.inverted_index.get(term)) |posting_list| {
                // Enhanced IDF calculation with smoothing
                const doc_freq = @as(f32, @floatFromInt(posting_list.documents.len));
                const idf = std.math.log(f32, std.math.e, ((total_docs - doc_freq + 0.5) / (doc_freq + 0.5)) + 1.0);

                for (posting_list.documents) |posting| {
                    const doc = self.documents.get(posting.doc_id) orelse continue;
                    const doc_len = @as(f32, @floatFromInt(doc.tokens.len));

                    // BM25 with query term frequency
                    const tf = posting.tf;
                    const norm_factor = 1.0 - b + b * (doc_len / avg_doc_len);
                    const doc_score = (tf * (k1 + 1.0)) / (tf + k1 * norm_factor);
                    const query_score = (qtf * (k3 + 1.0)) / (qtf + k3);
                    const score = idf * doc_score * query_score;

                    const current_score = scores.get(posting.doc_id) orelse 0;
                    try scores.put(posting.doc_id, current_score + score);
                }
            }
        }

        // Convert to results
        var results = std.ArrayList(SearchResult).init(self.allocator);
        var score_it = scores.iterator();
        while (score_it.next()) |entry| {
            try results.append(self.allocator, .{
                .doc_id = entry.key_ptr.*,
                .score = entry.value_ptr.*,
                .highlights = &[_]Highlight{},
            });
        }

        // Sort by score descending
        std.mem.sort(SearchResult, results.items, {}, struct {
            fn lessThan(_: void, lhs: SearchResult, rhs: SearchResult) bool {
                return lhs.score > rhs.score;
            }
        }.lessThan);

        // Return top results
        const n = @min(max_results, results.items.len);
        return results.items[0..n];
    }

    // Helper functions
    fn tokenize(self: *FullTextIndex, text: []const u8) ![]Token {
        var tokens = try std.ArrayList(Token).initCapacity(self.allocator, 0);
        var i: usize = 0;

        while (i < text.len) {
            // Skip whitespace
            while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}

            if (i >= text.len) break;

            const start = i;
            // Collect word characters
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) : (i += 1) {}

            if (i > start) {
                try tokens.append(self.allocator, .{
                    .text = text[start..i],
                    .position = tokens.items.len,
                    .offset = start,
                    .length = i - start,
                });
            }
        }

        return tokens.toOwnedSlice(self.allocator);
    }

    fn normalize(self: *FullTextIndex, text: []const u8) ![]u8 {
        // Unicode-aware normalization: NFC then case fold (minimal subset implementation)
        // CANARY: REQ=REQ-GQL-UNICODE-007; FEATURE="UnicodeFtsIntegration"; ASPECT=IndexerNormalize; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_007_FtsNormalize; OWNER=unicode; UPDATED=2025-09-27
        const unicode = @import("../unicode/geode_unicode.zig");
        const nfc = try unicode.nfcNormalize(self.allocator, text);
        defer self.allocator.free(nfc);
        const folded = try unicode.foldCase(self.allocator, nfc);
        return folded; // caller owns
    }

    fn updateIdfScores(self: *FullTextIndex) !void {
        const total_docs = @as(f32, @floatFromInt(self.documents.count()));

        var it = self.inverted_index.iterator();
        while (it.next()) |entry| {
            const doc_freq = @as(f32, @floatFromInt(entry.value_ptr.documents.len));
            entry.value_ptr.idf = std.math.log(f32, std.math.e, (total_docs + 1.0) / (doc_freq + 1.0));

            // Update TF-IDF scores
            for (entry.value_ptr.documents) |*posting| {
                posting.tf_idf = posting.tf * entry.value_ptr.idf;
            }
        }
    }

    fn getAverageDocumentLength(self: *FullTextIndex) !f32 {
        if (self.documents.count() == 0) return 0;

        var total_length: usize = 0;
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            total_length += entry.value_ptr.tokens.len;
        }

        return @as(f32, @floatFromInt(total_length)) / @as(f32, @floatFromInt(self.documents.count()));
    }

    // Index a new document
    // CANARY: REQ=REQ-GQL-FTS-002; FEATURE="Document Indexing"; ASPECT=FTS; STATUS=TESTED; TEST=TestCANARY_DocumentIndexing; OWNER=index; UPDATED=2025-09-29
    pub fn indexDocument(self: *FullTextIndex, doc_id: u64, content: []const u8) !void {
        // Tokenize content
        const tokens = try self.tokenize(content);
        defer self.allocator.free(tokens);

        // Store document
        const doc = Document{
            .id = doc_id,
            .content = try self.allocator.dupe(u8, content),
            .tokens = tokens,
            .vector = null, // Vector embeddings can be added later
        };
        try self.documents.put(doc_id, doc);

        // Build inverted index
        var term_positions = std.StringHashMap(std.ArrayList(usize)).init(self.allocator);
        defer {
            var it = term_positions.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            term_positions.deinit();
        }

        // Collect term positions
        for (tokens, 0..) |token, pos| {
            if (self.stopwords.contains(token.text)) continue;

            const normalized = try self.normalize(token.text);

            var positions = term_positions.get(normalized) orelse try std.ArrayList(usize).initCapacity(self.allocator, 0);
            try positions.append(self.allocator, pos);
            try term_positions.put(normalized, positions);
        }

        // Update inverted index
        var it = term_positions.iterator();
        while (it.next()) |entry| {
            const term = entry.key_ptr.*;
            const positions = entry.value_ptr.*;

            // Calculate term frequency
            const tf = @as(f32, @floatFromInt(positions.items.len)) / @as(f32, @floatFromInt(tokens.len));

            // Get or create posting list
            var posting_list = self.inverted_index.get(term) orelse PostingList{
                .term = try self.allocator.dupe(u8, term),
                .documents = &[_]PostingEntry{},
                .idf = 0,
            };

            // Add posting entry
            const posting = PostingEntry{
                .doc_id = doc_id,
                .positions = try self.allocator.dupe(usize, positions.items),
                .tf = tf,
                .tf_idf = 0, // Will be updated when IDF is recalculated
            };

            // Append to documents array
            var new_docs = try self.allocator.alloc(PostingEntry, posting_list.documents.len + 1);
            @memcpy(new_docs[0..posting_list.documents.len], posting_list.documents);
            new_docs[posting_list.documents.len] = posting;

            if (posting_list.documents.len > 0) {
                self.allocator.free(posting_list.documents);
            }
            posting_list.documents = new_docs;

            try self.inverted_index.put(term, posting_list);
        }

        // Update IDF scores
        try self.updateIdfScores();
    }

    // Remove a document from the index
    pub fn removeDocument(self: *FullTextIndex, doc_id: u64) !void {
        // Remove from documents
        if (self.documents.fetchRemove(doc_id)) |entry| {
            self.allocator.free(entry.value.content);
            self.allocator.free(entry.value.tokens);
            if (entry.value.vector) |vec| {
                self.allocator.free(vec);
            }
        }

        // Remove from inverted index
        var it = self.inverted_index.iterator();
        while (it.next()) |entry| {
            var posting_list = entry.value_ptr.*;

            // Filter out the document
            var new_docs = try std.ArrayList(PostingEntry).initCapacity(self.allocator, 0);
            for (posting_list.documents) |posting| {
                if (posting.doc_id != doc_id) {
                    try new_docs.append(self.allocator, posting);
                } else {
                    self.allocator.free(posting.positions);
                }
            }

            if (posting_list.documents.len > 0) {
                self.allocator.free(posting_list.documents);
            }
            posting_list.documents = new_docs.toOwnedSlice(self.allocator);
        }

        // Update IDF scores
        try self.updateIdfScores();
    }
};
