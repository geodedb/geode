const std = @import("std");

// CANARY: REQ=REQ-REPL-FUZZY-001; FEATURE="REPL Fuzzy Search"; ASPECT=Implementation; STATUS=IMPL; TEST=test_fuzzy_search; OWNER=repl; UPDATED=2025-11-17

/// Result of a fuzzy search match
pub const FuzzyMatch = struct {
    text: []const u8,
    score: i32,
    index: usize,

    pub fn lessThan(context: void, a: FuzzyMatch, b: FuzzyMatch) bool {
        _ = context;
        return a.score > b.score; // Higher scores first
    }
};

/// Calculate Levenshtein distance between two strings
pub fn levenshteinDistance(allocator: std.mem.Allocator, s1: []const u8, s2: []const u8) !usize {
    if (s1.len == 0) return s2.len;
    if (s2.len == 0) return s1.len;

    // Create matrix
    const rows = s1.len + 1;
    const cols = s2.len + 1;
    var matrix = try allocator.alloc(usize, rows * cols);
    defer allocator.free(matrix);

    // Initialize first column and row
    for (0..rows) |i| {
        matrix[i * cols] = i;
    }
    for (0..cols) |j| {
        matrix[j] = j;
    }

    // Fill matrix
    for (1..rows) |i| {
        for (1..cols) |j| {
            const cost: usize = if (s1[i - 1] == s2[j - 1]) 0 else 1;
            const deletion = matrix[(i - 1) * cols + j] + 1;
            const insertion = matrix[i * cols + (j - 1)] + 1;
            const substitution = matrix[(i - 1) * cols + (j - 1)] + cost;

            matrix[i * cols + j] = @min(@min(deletion, insertion), substitution);
        }
    }

    return matrix[(rows - 1) * cols + (cols - 1)];
}

/// Calculate fuzzy match score (higher is better)
pub fn fuzzyScore(allocator: std.mem.Allocator, query: []const u8, text: []const u8) !i32 {
    if (query.len == 0) return 0;
    if (text.len == 0) return -1000;

    // Case-insensitive comparison
    var query_lower = try allocator.alloc(u8, query.len);
    defer allocator.free(query_lower);
    var text_lower = try allocator.alloc(u8, text.len);
    defer allocator.free(text_lower);

    for (query, 0..) |c, i| {
        query_lower[i] = std.ascii.toLower(c);
    }
    for (text, 0..) |c, i| {
        text_lower[i] = std.ascii.toLower(c);
    }

    var score: i32 = 0;

    // Exact match bonus
    if (std.mem.eql(u8, query_lower, text_lower)) {
        return 5000;
    }

    // Starts with bonus
    if (std.mem.startsWith(u8, text_lower, query_lower)) {
        score += 500;
    }

    // Contains bonus
    if (std.mem.indexOf(u8, text_lower, query_lower)) |pos| {
        score += 300;
        // Earlier matches are better
        score -= @as(i32, @intCast(pos)) * 2;
    }

    // Consecutive character matching
    var query_idx: usize = 0;
    var consecutive: i32 = 0;
    var max_consecutive: i32 = 0;

    for (text_lower, 0..) |c, i| {
        if (query_idx < query_lower.len and c == query_lower[query_idx]) {
            query_idx += 1;
            consecutive += 1;
            max_consecutive = @max(max_consecutive, consecutive);

            // Bonus for word boundary matches
            if (i == 0 or !std.ascii.isAlphanumeric(text_lower[i - 1])) {
                score += 20;
            }
        } else {
            consecutive = 0;
        }
    }

    // Did we match all query characters?
    if (query_idx == query_lower.len) {
        score += 200;
        score += max_consecutive * 10;
    } else {
        // Penalty for not matching all characters
        score -= @as(i32, @intCast((query_lower.len - query_idx) * 50));
    }

    // Levenshtein distance penalty
    const distance = try levenshteinDistance(allocator, query_lower, text_lower);
    score -= @as(i32, @intCast(distance)) * 10;

    // Length penalty (prefer shorter matches)
    const length_diff = if (text.len > query.len) text.len - query.len else 0;
    score -= @as(i32, @intCast(length_diff));

    return score;
}

/// Search a list of strings and return matches sorted by score
pub fn fuzzySearch(
    allocator: std.mem.Allocator,
    query: []const u8,
    candidates: []const []const u8,
    max_results: usize,
) ![]FuzzyMatch {
    var matches = std.ArrayList(FuzzyMatch){};
    defer matches.deinit(allocator);

    for (candidates, 0..) |text, i| {
        const score = try fuzzyScore(allocator, query, text);
        if (score > -500) { // Only include reasonable matches
            try matches.append(allocator, .{
                .text = text,
                .score = score,
                .index = i,
            });
        }
    }

    // Sort by score (highest first)
    std.mem.sort(FuzzyMatch, matches.items, {}, FuzzyMatch.lessThan);

    // Limit results
    const result_count = @min(max_results, matches.items.len);
    const result = try allocator.alloc(FuzzyMatch, result_count);
    @memcpy(result, matches.items[0..result_count]);

    return result;
}

/// Interactive fuzzy finder for history
pub const FuzzyFinder = struct {
    allocator: std.mem.Allocator,
    candidates: []const []const u8,
    query: std.ArrayList(u8),
    selected_index: usize = 0,
    max_display: usize = 10,

    pub fn init(allocator: std.mem.Allocator, candidates: []const []const u8) !FuzzyFinder {
        return .{
            .allocator = allocator,
            .candidates = candidates,
            .query = std.ArrayList(u8){},
        };
    }

    pub fn deinit(self: *FuzzyFinder) void {
        self.query.deinit(self.allocator);
    }

    pub fn updateQuery(self: *FuzzyFinder, query: []const u8) !void {
        self.query.clearRetainingCapacity();
        try self.query.appendSlice(self.allocator, query);
        self.selected_index = 0;
    }

    pub fn getMatches(self: *FuzzyFinder) ![]FuzzyMatch {
        if (self.query.items.len == 0) {
            // No query - return all candidates
            const result = try self.allocator.alloc(FuzzyMatch, @min(self.max_display, self.candidates.len));
            for (self.candidates[0..result.len], 0..) |text, i| {
                result[i] = .{
                    .text = text,
                    .score = 0,
                    .index = i,
                };
            }
            return result;
        }

        return fuzzySearch(
            self.allocator,
            self.query.items,
            self.candidates,
            self.max_display,
        );
    }

    pub fn selectNext(self: *FuzzyFinder, matches: []const FuzzyMatch) void {
        if (matches.len == 0) return;
        self.selected_index = (self.selected_index + 1) % matches.len;
    }

    pub fn selectPrev(self: *FuzzyFinder, matches: []const FuzzyMatch) void {
        if (matches.len == 0) return;
        if (self.selected_index == 0) {
            self.selected_index = matches.len - 1;
        } else {
            self.selected_index -= 1;
        }
    }

    pub fn getSelected(self: *const FuzzyFinder, matches: []const FuzzyMatch) ?[]const u8 {
        if (self.selected_index >= matches.len) return null;
        return matches[self.selected_index].text;
    }
};

test "levenshteinDistance basic cases" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqual(@as(usize, 0), try levenshteinDistance(allocator, "hello", "hello"));
    try std.testing.expectEqual(@as(usize, 5), try levenshteinDistance(allocator, "hello", ""));
    try std.testing.expectEqual(@as(usize, 5), try levenshteinDistance(allocator, "", "hello"));
    try std.testing.expectEqual(@as(usize, 1), try levenshteinDistance(allocator, "cat", "bat"));
    try std.testing.expectEqual(@as(usize, 3), try levenshteinDistance(allocator, "kitten", "sitting"));
}

test "fuzzyScore exact match" {
    const allocator = std.testing.allocator;
    const score = try fuzzyScore(allocator, "hello", "hello");
    try std.testing.expect(score >= 1000); // Exact match should have high score
}

test "fuzzyScore starts with" {
    const allocator = std.testing.allocator;
    const score = try fuzzyScore(allocator, "hel", "hello world");
    try std.testing.expect(score > 0); // Should have positive score
}

test "fuzzyScore case insensitive" {
    const allocator = std.testing.allocator;
    const score1 = try fuzzyScore(allocator, "hello", "HELLO");
    const score2 = try fuzzyScore(allocator, "HELLO", "hello");
    try std.testing.expectEqual(score1, score2);
    try std.testing.expect(score1 >= 1000); // Exact match (case insensitive)
}

test "fuzzySearch returns sorted results" {
    const allocator = std.testing.allocator;

    const candidates = [_][]const u8{
        "MATCH (n) RETURN n",
        "MATCH (n:Person) RETURN n.name",
        "CREATE (n:Node)",
        "MERGE (n) RETURN n",
    };

    const results = try fuzzySearch(allocator, "match", &candidates, 10);
    defer allocator.free(results);

    // Should find at least 2 matches
    try std.testing.expect(results.len >= 2);

    // Scores should be descending
    for (results[0 .. results.len - 1], 0..) |match, i| {
        try std.testing.expect(match.score >= results[i + 1].score);
    }
}

test "fuzzySearch limits results" {
    const allocator = std.testing.allocator;

    const candidates = [_][]const u8{
        "MATCH (n) RETURN n",
        "MATCH (n:Person) RETURN n.name",
        "MATCH (n:Product) RETURN n.price",
        "MATCH (n:Order) RETURN n.total",
    };

    const results = try fuzzySearch(allocator, "match", &candidates, 2);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "FuzzyFinder basic workflow" {
    const allocator = std.testing.allocator;

    const candidates = [_][]const u8{
        "MATCH (n) RETURN n",
        "CREATE (n:Node)",
        "DELETE n",
    };

    var finder = try FuzzyFinder.init(allocator, &candidates);
    defer finder.deinit();

    // Initial state - no query
    const matches = try finder.getMatches();
    defer allocator.free(matches);
    try std.testing.expect(matches.len > 0);

    // Update query
    try finder.updateQuery("match");
    const new_matches = try finder.getMatches();
    defer allocator.free(new_matches);

    // Should find MATCH query
    try std.testing.expect(new_matches.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, new_matches[0].text, "MATCH") != null);
}
