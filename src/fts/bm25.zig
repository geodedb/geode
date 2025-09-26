const std = @import("std");

// BM25 Scoring Implementation (formerly flag gated - now always available)
// CANARY: REQ=REQ-GQL-FTS-001; FEATURE="BM25 Scoring"; ASPECT=SEARCH; STATUS=TESTED; TEST=tests/e2e_fts_advanced.zig:1; BENCH=tests/benchmark_fts_bm25_scoring.zig:1; OWNER=search; UPDATED=2025-09-26

pub const Params = struct {
    k1: f64 = 1.2,
    b: f64 = 0.75,
};

pub fn score(doc_tf: f64, doc_len: f64, avg_doc_len: f64, doc_freq: f64, total_docs: f64, params: Params) f64 {
    if (doc_tf == 0 or doc_len == 0 or avg_doc_len == 0 or doc_freq == 0) return 0;
    const idf = @log((total_docs - doc_freq + 0.5) / (doc_freq + 0.5));
    const norm = doc_tf * (params.k1 + 1) / (doc_tf + params.k1 * (1 - params.b + params.b * (doc_len / avg_doc_len)));
    return idf * norm;
}

// BM25F variant for multiple fields with weights
pub const BM25F = struct {
    params: Params,
    field_weights: std.StringHashMap(f64),
    field_lengths: std.StringHashMap(f64),
    
    pub fn init(allocator: std.mem.Allocator) BM25F {
        return .{
            .params = .{},
            .field_weights = std.StringHashMap(f64).init(allocator),
            .field_lengths = std.StringHashMap(f64).init(allocator),
        };
    }
    
    pub fn deinit(self: *BM25F) void {
        self.field_weights.deinit();
        self.field_lengths.deinit();
    }
    
    pub fn addFieldWeight(self: *BM25F, field: []const u8, weight: f64) !void {
        try self.field_weights.put(field, weight);
    }
    
    pub fn scoreMultiField(
        self: *BM25F,
        field_tfs: std.StringHashMap(f64),
        doc_lens: std.StringHashMap(f64),
        avg_lens: std.StringHashMap(f64),
        doc_freq: f64,
        total_docs: f64,
    ) f64 {
        var weighted_tf: f64 = 0;
        var weighted_len: f64 = 0;
        var total_weight: f64 = 0;
        
        var it = field_tfs.iterator();
        while (it.next()) |entry| {
            const field = entry.key_ptr.*;
            const tf = entry.value_ptr.*;
            const weight = self.field_weights.get(field) orelse 1.0;
            const doc_len = doc_lens.get(field) orelse 0;
            const avg_len = avg_lens.get(field) orelse 1;
            
            weighted_tf += tf * weight;
            weighted_len += (doc_len / avg_len) * weight;
            total_weight += weight;
        }
        
        if (total_weight == 0) return 0;
        
        weighted_tf /= total_weight;
        weighted_len /= total_weight;
        
        const idf = @log((total_docs - doc_freq + 0.5) / (doc_freq + 0.5));
        const norm = weighted_tf * (self.params.k1 + 1) / 
                    (weighted_tf + self.params.k1 * (1 - self.params.b + self.params.b * weighted_len));
        
        return idf * norm;
    }
};

// Document statistics for BM25 scoring
pub const DocStats = struct {
    doc_id: u64,
    term_frequency: std.StringHashMap(u32),
    field_lengths: std.StringHashMap(u32),
    total_terms: u32,
    
    pub fn init(allocator: std.mem.Allocator, doc_id: u64) DocStats {
        return .{
            .doc_id = doc_id,
            .term_frequency = std.StringHashMap(u32).init(allocator),
            .field_lengths = std.StringHashMap(u32).init(allocator),
            .total_terms = 0,
        };
    }
    
    pub fn deinit(self: *DocStats) void {
        self.term_frequency.deinit();
        self.field_lengths.deinit();
    }
    
    pub fn addTerm(self: *DocStats, term: []const u8, field: []const u8) !void {
        const key = try std.fmt.allocPrint(self.term_frequency.allocator, "{s}:{s}", .{ field, term });
        defer self.term_frequency.allocator.free(key);
        
        const result = try self.term_frequency.getOrPut(key);
        if (!result.found_existing) {
            result.value_ptr.* = 0;
        }
        result.value_ptr.* += 1;
        
        const field_result = try self.field_lengths.getOrPut(field);
        if (!field_result.found_existing) {
            field_result.value_ptr.* = 0;
        }
        field_result.value_ptr.* += 1;
        
        self.total_terms += 1;
    }
};

// Index statistics for IDF calculation
pub const IndexStats = struct {
    total_docs: u64,
    doc_frequencies: std.StringHashMap(u64),
    avg_doc_length: f64,
    field_avg_lengths: std.StringHashMap(f64),
    
    pub fn init(allocator: std.mem.Allocator) IndexStats {
        return .{
            .total_docs = 0,
            .doc_frequencies = std.StringHashMap(u64).init(allocator),
            .avg_doc_length = 0,
            .field_avg_lengths = std.StringHashMap(f64).init(allocator),
        };
    }
    
    pub fn deinit(self: *IndexStats) void {
        self.doc_frequencies.deinit();
        self.field_avg_lengths.deinit();
    }
    
    pub fn updateFromDoc(self: *IndexStats, doc_stats: *const DocStats) !void {
        self.total_docs += 1;
        
        // Update document frequencies
        var it = doc_stats.term_frequency.iterator();
        while (it.next()) |entry| {
            const term = entry.key_ptr.*;
            if (entry.value_ptr.* > 0) {
                const result = try self.doc_frequencies.getOrPut(term);
                if (!result.found_existing) {
                    result.value_ptr.* = 0;
                }
                result.value_ptr.* += 1;
            }
        }
        
        // Update average lengths
        const doc_len = @as(f64, @floatFromInt(doc_stats.total_terms));
        self.avg_doc_length = (self.avg_doc_length * @as(f64, @floatFromInt(self.total_docs - 1)) + doc_len) / 
                             @as(f64, @floatFromInt(self.total_docs));
        
        var field_it = doc_stats.field_lengths.iterator();
        while (field_it.next()) |field_entry| {
            const field = field_entry.key_ptr.*;
            const length = @as(f64, @floatFromInt(field_entry.value_ptr.*));
            
            const result = try self.field_avg_lengths.getOrPut(field);
            if (!result.found_existing) {
                result.value_ptr.* = length;
            } else {
                result.value_ptr.* = (result.value_ptr.* * @as(f64, @floatFromInt(self.total_docs - 1)) + length) / 
                                    @as(f64, @floatFromInt(self.total_docs));
            }
        }
    }
};

// Ranked search results
pub const SearchResult = struct {
    doc_id: u64,
    score: f64,
    highlights: []const []const u8,
    
    pub fn compare(_: void, a: SearchResult, b: SearchResult) bool {
        return a.score > b.score; // Higher scores first
    }
};

// BM25 search engine
pub const SearchEngine = struct {
    allocator: std.mem.Allocator,
    index_stats: IndexStats,
    doc_stats: std.AutoHashMap(u64, DocStats),
    params: Params,
    
    pub fn init(allocator: std.mem.Allocator) SearchEngine {
        return .{
            .allocator = allocator,
            .index_stats = IndexStats.init(allocator),
            .doc_stats = std.AutoHashMap(u64, DocStats).init(allocator),
            .params = .{},
        };
    }
    
    pub fn deinit(self: *SearchEngine) void {
        self.index_stats.deinit();
        var it = self.doc_stats.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.doc_stats.deinit();
    }
    
    pub fn search(
        self: *SearchEngine,
        query_terms: []const []const u8,
        max_results: usize,
    ) ![]SearchResult {
        var results = std.ArrayList(SearchResult).init(self.allocator);
        defer results.deinit();
        
        var doc_it = self.doc_stats.iterator();
        while (doc_it.next()) |doc_entry| {
            const doc_id = doc_entry.key_ptr.*;
            const doc_stat = doc_entry.value_ptr.*;
            
            var total_score: f64 = 0;
            for (query_terms) |term| {
                const tf = @as(f64, @floatFromInt(doc_stat.term_frequency.get(term) orelse 0));
                const df = @as(f64, @floatFromInt(self.index_stats.doc_frequencies.get(term) orelse 0));
                const doc_len = @as(f64, @floatFromInt(doc_stat.total_terms));
                
                total_score += score(
                    tf,
                    doc_len,
                    self.index_stats.avg_doc_length,
                    df,
                    @as(f64, @floatFromInt(self.index_stats.total_docs)),
                    self.params,
                );
            }
            
            if (total_score > 0) {
                try results.append(.{
                    .doc_id = doc_id,
                    .score = total_score,
                    .highlights = &[_][]const u8{},
                });
            }
        }
        
        // Sort by score
        std.sort.heap(SearchResult, results.items, {}, SearchResult.compare);
        
        // Return top N results
        const n = @min(max_results, results.items.len);
        return try self.allocator.dupe(SearchResult, results.items[0..n]);
    }
};
