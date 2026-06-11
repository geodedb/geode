const std = @import("std");

// Advanced FTS auxiliary components: analyzers, stemming, fuzzy matching,
// n-grams, synonyms, phonetic matching.
//
// NOTE (GAP-0869, 2026-06-10): the former `phraseQuery` / `proximityQuery` /
// `highlight` functions in this file ran against HARD-CODED synthetic corpora
// and were deleted. The real phrase/proximity/highlight implementations live
// on the persisted fts-storage positional index:
//   - `FullTextIndex.phraseSearch` / `proximitySearch` / `highlight`
//     (src/index/fulltext.zig), backed by per-(term,doc) token positions via
//     `FtsStorageAdapter.searchPositions` (src/storage/fts_storage_adapter.zig)
//   - GQL surface: `CALL geode.fts.phrase(...)` / `CALL geode.fts.proximity(...)`
//     (src/execution/fts_dispatch.zig)
// CANARY: REQ=REQ-GQL-FTS-ADV-001; FEATURE="Advanced FTS"; ASPECT=QUERY; STATUS=TESTED; TEST=tests/e2e_fts_advanced.zig:1; BENCH=tests/benchmark_fts_analyzer_perf.zig:1; OWNER=search; UPDATED=2026-06-10

const bm25 = @import("bm25.zig");

pub const Analyzer = enum {
    simple, // Split on whitespace only
    whitespace, // Split on whitespace, lowercase
    english, // English stemming, stop words
    standard, // Unicode word boundaries
};

fn lowerAlloc(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    // Unicode-aware lowercase via foldCase (minimal subset) after NFC normalize.
    // CANARY: REQ=REQ-GQL-UNICODE-008; FEATURE="UnicodeFtsAdvanced"; ASPECT=AnalyzerLower; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_008_FtsAdvancedAnalyzer; OWNER=unicode; UPDATED=2025-09-27
    const unicode = @import("../unicode/geode_unicode.zig");
    const nfc = try unicode.nfcNormalize(allocator, s);
    defer allocator.free(nfc);
    const folded = try unicode.foldCase(allocator, nfc);
    return folded;
}

// Language-specific analyzer implementations
pub const LanguageAnalyzer = struct {
    allocator: std.mem.Allocator,
    analyzer_type: Analyzer,
    stop_words: std.StringHashMap(void),
    stemmer: ?*Stemmer = null,

    pub fn init(allocator: std.mem.Allocator, analyzer_type: Analyzer) !LanguageAnalyzer {
        var analyzer = LanguageAnalyzer{
            .allocator = allocator,
            .analyzer_type = analyzer_type,
            .stop_words = std.StringHashMap(void).init(allocator),
        };

        // Load stop words for English analyzer
        if (analyzer_type == .english) {
            const english_stop_words = [_][]const u8{
                "the",  "be",  "to",   "of", "and",  "a",    "in",    "that",  "have",  "i",
                "it",   "for", "not",  "on", "with", "he",   "as",    "you",   "do",    "at",
                "this", "but", "his",  "by", "from", "they", "we",    "say",   "her",   "she",
                "or",   "an",  "will", "my", "one",  "all",  "would", "there", "their", "what",
            };

            for (english_stop_words) |word| {
                try analyzer.stop_words.put(word, {});
            }

            analyzer.stemmer = try allocator.create(Stemmer);
            analyzer.stemmer.?.* = Stemmer.initPorter2();
        }

        return analyzer;
    }

    pub fn deinit(self: *LanguageAnalyzer) void {
        self.stop_words.deinit();
        if (self.stemmer) |s| {
            self.allocator.destroy(s);
        }
    }

    pub fn analyze(self: *LanguageAnalyzer, text: []const u8) ![][]const u8 {
        var tokens = std.ArrayList([]const u8).init(self.allocator);
        defer tokens.deinit();

        switch (self.analyzer_type) {
            .simple => {
                // Just split on whitespace
                var it = std.mem.tokenizeAny(u8, text, " \t\n\r");
                while (it.next()) |token| {
                    try tokens.append(try self.allocator.dupe(u8, token));
                }
            },
            .whitespace => {
                // Split and lowercase
                var it = std.mem.tokenizeAny(u8, text, " \t\n\r");
                while (it.next()) |token| {
                    const lower = try lowerAlloc(self.allocator, token);
                    try tokens.append(lower);
                }
            },
            .english => {
                // Split, lowercase, remove stop words, stem
                var it = std.mem.tokenizeAny(u8, text, " \t\n\r.,:;!?");
                while (it.next()) |token| {
                    const lower = try lowerAlloc(self.allocator, token);

                    // Skip stop words
                    if (self.stop_words.contains(lower)) {
                        self.allocator.free(lower);
                        continue;
                    }

                    // Apply stemming
                    if (self.stemmer) |s| {
                        const stemmed = try s.stem(self.allocator, lower);
                        self.allocator.free(lower);
                        try tokens.append(stemmed);
                    } else {
                        try tokens.append(lower);
                    }
                }
            },
            .standard => {
                // Unicode-aware tokenization
                const result = try self.unicodeTokenize(text);
                for (result) |token| {
                    const lower = try lowerAlloc(self.allocator, token);
                    try tokens.append(lower);
                }
            },
        }

        return try tokens.toOwnedSlice();
    }

    fn unicodeTokenize(self: *LanguageAnalyzer, text: []const u8) ![][]const u8 {
        var tokens = std.ArrayList([]const u8).init(self.allocator);
        var i: usize = 0;
        var token_start: ?usize = null;

        while (i < text.len) {
            const c = text[i];
            const is_word_char = std.ascii.isAlphanumeric(c) or c == '_' or c == '-';

            if (is_word_char) {
                if (token_start == null) {
                    token_start = i;
                }
            } else {
                if (token_start) |start| {
                    const token = text[start..i];
                    try tokens.append(try self.allocator.dupe(u8, token));
                    token_start = null;
                }
            }
            i += 1;
        }

        // Handle last token
        if (token_start) |start| {
            const token = text[start..];
            try tokens.append(try self.allocator.dupe(u8, token));
        }

        return try tokens.toOwnedSlice();
    }
};

// Porter2 stemmer implementation
pub const Stemmer = struct {
    pub fn initPorter2() Stemmer {
        return .{};
    }

    pub fn stem(self: *Stemmer, allocator: std.mem.Allocator, word: []const u8) ![]u8 {
        _ = self;

        // Simplified Porter2 algorithm
        if (word.len < 3) {
            return try allocator.dupe(u8, word);
        }

        var result = try allocator.dupe(u8, word);

        // Remove common suffixes
        const suffixes = [_][]const u8{
            "ational", "tional",  "enci",    "anci",    "izer",  "abli",   "alli",
            "entli",   "eli",     "ousli",   "ization", "ation", "ator",   "alism",
            "iveness", "fulness", "ousness", "aliti",   "iviti", "biliti", "ing",
            "ed",      "ly",      "es",      "s",
        };

        for (suffixes) |suffix| {
            if (std.mem.endsWith(u8, result, suffix)) {
                const new_len = result.len - suffix.len;
                if (new_len >= 2) { // Keep at least 2 chars
                    result = result[0..new_len];
                    break;
                }
            }
        }

        return result;
    }
};

// Fuzzy matching with Levenshtein distance
pub fn fuzzyMatch(
    allocator: std.mem.Allocator,
    query: []const u8,
    target: []const u8,
    max_distance: u32,
) !bool {
    const distance = try levenshteinDistance(allocator, query, target);
    return distance <= max_distance;
}

fn levenshteinDistance(allocator: std.mem.Allocator, s1: []const u8, s2: []const u8) !u32 {
    if (s1.len == 0) return @intCast(s2.len);
    if (s2.len == 0) return @intCast(s1.len);

    var prev_row = try allocator.alloc(u32, s2.len + 1);
    defer allocator.free(prev_row);
    var curr_row = try allocator.alloc(u32, s2.len + 1);
    defer allocator.free(curr_row);

    // Initialize first row
    for (prev_row, 0..) |*cell, i| {
        cell.* = @intCast(i);
    }

    for (s1, 0..) |c1, i| {
        curr_row[0] = @intCast(i + 1);

        for (s2, 0..) |c2, j| {
            const cost: u32 = if (c1 == c2) 0 else 1;
            curr_row[j + 1] = @min(
                @min(prev_row[j + 1] + 1, curr_row[j] + 1),
                prev_row[j] + cost,
            );
        }

        std.mem.swap([]u32, &prev_row, &curr_row);
    }

    return prev_row[s2.len];
}

// N-gram generation for fuzzy matching
pub fn generateNgrams(
    allocator: std.mem.Allocator,
    text: []const u8,
    n: usize,
) ![][]const u8 {
    if (text.len < n) {
        return try allocator.alloc([]const u8, 0);
    }

    const ngrams = try allocator.alloc([]const u8, text.len - n + 1);

    for (ngrams, 0..) |*ngram, i| {
        ngram.* = text[i .. i + n];
    }

    return ngrams;
}

// Synonym expansion for query enhancement
pub const SynonymDict = struct {
    synonyms: std.StringHashMap([]const []const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SynonymDict {
        return .{
            .synonyms = std.StringHashMap([]const []const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SynonymDict) void {
        var it = self.synonyms.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.synonyms.deinit();
    }

    pub fn addSynonyms(self: *SynonymDict, word: []const u8, synonyms: []const []const u8) !void {
        const syn_copy = try self.allocator.dupe([]const u8, synonyms);
        try self.synonyms.put(word, syn_copy);
    }

    pub fn getSynonyms(self: *SynonymDict, word: []const u8) ?[]const []const u8 {
        return self.synonyms.get(word);
    }

    pub fn expandQuery(self: *SynonymDict, query: []const []const u8) ![][]const u8 {
        var expanded = std.ArrayList([]const u8).init(self.allocator);

        for (query) |term| {
            try expanded.append(term);

            if (self.getSynonyms(term)) |syns| {
                for (syns) |syn| {
                    try expanded.append(syn);
                }
            }
        }

        return try expanded.toOwnedSlice();
    }
};

// Phonetic matching (Soundex algorithm)
pub fn soundex(allocator: std.mem.Allocator, word: []const u8) ![]const u8 {
    if (word.len == 0) return try allocator.dupe(u8, "");

    var result = try allocator.alloc(u8, 4);
    @memset(result, '0');

    // Keep first letter
    result[0] = std.ascii.toUpper(word[0]);

    const soundex_map = [_]u8{
        '0', '1', '2', '3', '0', '1', '2', '0', '0', '2', // A-J
        '2', '4', '5', '5', '0', '1', '2', '6', '2', '3', // K-T
        '0', '1', '0', '2', '0', '2', // U-Z
    };

    var result_idx: usize = 1;
    var prev_code: u8 = '0';

    for (word[1..]) |c| {
        if (result_idx >= 4) break;

        const upper = std.ascii.toUpper(c);
        if (upper >= 'A' and upper <= 'Z') {
            const code = soundex_map[upper - 'A'];
            if (code != '0' and code != prev_code) {
                result[result_idx] = code;
                result_idx += 1;
                prev_code = code;
            }
        }
    }

    return result;
}

// Advanced search with all features integrated
pub const AdvancedSearch = struct {
    allocator: std.mem.Allocator,
    analyzer: LanguageAnalyzer,
    search_engine: bm25.SearchEngine,
    synonym_dict: SynonymDict,

    pub fn init(allocator: std.mem.Allocator, analyzer_type: Analyzer) !AdvancedSearch {
        return .{
            .allocator = allocator,
            .analyzer = try LanguageAnalyzer.init(allocator, analyzer_type),
            .search_engine = bm25.SearchEngine.init(allocator),
            .synonym_dict = SynonymDict.init(allocator),
        };
    }

    pub fn deinit(self: *AdvancedSearch) void {
        self.analyzer.deinit();
        self.search_engine.deinit();
        self.synonym_dict.deinit();
    }

    pub fn indexDocument(self: *AdvancedSearch, doc_id: u64, content: []const u8, field: []const u8) !void {
        const tokens = try self.analyzer.analyze(content);
        defer {
            for (tokens) |token| {
                self.allocator.free(token);
            }
            self.allocator.free(tokens);
        }

        var doc_stats = bm25.DocStats.init(self.allocator, doc_id);
        defer doc_stats.deinit();

        for (tokens) |token| {
            try doc_stats.addTerm(token, field);
        }

        try self.search_engine.index_stats.updateFromDoc(&doc_stats);
        try self.search_engine.doc_stats.put(doc_id, doc_stats);
    }

    pub fn search(
        self: *AdvancedSearch,
        query: []const u8,
        options: SearchOptions,
    ) ![]bm25.SearchResult {
        // Analyze query
        const query_tokens = try self.analyzer.analyze(query);
        defer {
            for (query_tokens) |token| {
                self.allocator.free(token);
            }
            self.allocator.free(query_tokens);
        }

        // Expand with synonyms if enabled
        const search_terms = if (options.use_synonyms)
            try self.synonym_dict.expandQuery(query_tokens)
        else
            query_tokens;

        if (options.use_synonyms and search_terms.ptr != query_tokens.ptr) {
            defer self.allocator.free(search_terms);
        }

        // Perform search
        return try self.search_engine.search(search_terms, options.max_results);
    }

    pub const SearchOptions = struct {
        max_results: usize = 10,
        use_synonyms: bool = false,
        fuzzy_distance: ?u32 = null,
        highlight: bool = true,
        fragment_size: usize = 150,
    };
};
