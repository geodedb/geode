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

    // Search for documents matching a query
    pub fn search(self: *FullTextIndex, query: []const u8, max_results: usize) ![]SearchResult {
        const query_tokens = try self.tokenize(query);
        defer self.allocator.free(query_tokens);

        var scores = std.AutoHashMap(u64, f32).init(self.allocator);
        defer scores.deinit();

        // Calculate BM25 scores
        const k1: f32 = 1.2;
        const b: f32 = 0.75;
        const avg_doc_len = try self.getAverageDocumentLength();

        for (query_tokens) |token| {
            if (self.stopwords.contains(token.text)) continue;

            const normalized = try self.normalize(token.text);
            defer self.allocator.free(normalized);

            if (self.inverted_index.get(normalized)) |posting_list| {
                for (posting_list.documents) |posting| {
                    const doc = self.documents.get(posting.doc_id) orelse continue;
                    const doc_len = @as(f32, @floatFromInt(doc.tokens.len));

                    // BM25 scoring
                    const tf = posting.tf;
                    const idf = posting_list.idf;
                    const norm_factor = 1.0 - b + b * (doc_len / avg_doc_len);
                    const score = idf * ((tf * (k1 + 1.0)) / (tf + k1 * norm_factor));

                    const current_score = scores.get(posting.doc_id) orelse 0;
                    try scores.put(posting.doc_id, current_score + score);
                }
            }
        }

        // Convert to results
        var results = std.ArrayList(SearchResult).init(self.allocator);
        var score_it = scores.iterator();
        while (score_it.next()) |entry| {
            try results.append(.{
                .doc_id = entry.key_ptr.*,
                .score = entry.value_ptr.*,
                .highlights = &[_]Highlight{},
            });
        }

        // Sort by score descending
        std.sort.sort(SearchResult, results.items, {}, struct {
            fn lessThan(_: void, a: SearchResult, b: SearchResult) bool {
                return a.score > b.score;
            }
        }.lessThan);

        // Return top results
        const n = @min(max_results, results.items.len);
        return results.items[0..n];
    }

    // Helper functions
    fn tokenize(self: *FullTextIndex, text: []const u8) ![]Token {
        var tokens = std.ArrayList(Token).init(self.allocator);
        var i: usize = 0;

        while (i < text.len) {
            // Skip whitespace
            while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}

            if (i >= text.len) break;

            const start = i;
            // Collect word characters
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) : (i += 1) {}

            if (i > start) {
                try tokens.append(.{
                    .text = text[start..i],
                    .position = tokens.items.len,
                    .offset = start,
                    .length = i - start,
                });
            }
        }

        return tokens.toOwnedSlice();
    }

    fn normalize(self: *FullTextIndex, text: []const u8) ![]u8 {
        var normalized = try self.allocator.alloc(u8, text.len);
        for (text, 0..) |c, i| {
            normalized[i] = std.ascii.toLower(c);
        }
        return normalized;
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
};
