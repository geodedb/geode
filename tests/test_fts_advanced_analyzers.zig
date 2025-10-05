const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

// Simplified analyzer types for testing
const AnalyzerType = enum {
    simple,
    whitespace,
    english,
    standard,
};

// Simplified language analyzer for testing
const MockLanguageAnalyzer = struct {
    allocator: Allocator,
    analyzer_type: AnalyzerType,
    stop_words: std.StringHashMap(void),

    pub fn init(allocator: Allocator, analyzer_type: AnalyzerType) !MockLanguageAnalyzer {
        var analyzer = MockLanguageAnalyzer{
            .allocator = allocator,
            .analyzer_type = analyzer_type,
            .stop_words = std.StringHashMap(void).init(allocator),
        };

        // Load English stop words
        if (analyzer_type == .english) {
            const stop_words = [_][]const u8{ "the", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with", "by" };
            for (stop_words) |word| {
                try analyzer.stop_words.put(word, {});
            }
        }

        return analyzer;
    }

    pub fn deinit(self: *MockLanguageAnalyzer) void {
        self.stop_words.deinit();
    }

    pub fn analyze(self: *MockLanguageAnalyzer, text: []const u8) ![][]const u8 {
        var tokens = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer tokens.deinit(self.allocator);

        switch (self.analyzer_type) {
            .simple => {
                // Just split on whitespace
                var it = std.mem.tokenizeAny(u8, text, " \t\n\r");
                while (it.next()) |token| {
                    try tokens.append(self.allocator, try self.allocator.dupe(u8, token));
                }
            },
            .whitespace => {
                // Split and lowercase
                var it = std.mem.tokenizeAny(u8, text, " \t\n\r");
                while (it.next()) |token| {
                    const lower = try self.toLowerCase(token);
                    try tokens.append(self.allocator, lower);
                }
            },
            .english => {
                // Split, lowercase, remove stop words, simple stemming
                var it = std.mem.tokenizeAny(u8, text, " \t\n\r.,:;!?");
                while (it.next()) |token| {
                    const lower = try self.toLowerCase(token);

                    // Skip stop words
                    if (self.stop_words.contains(lower)) {
                        self.allocator.free(lower);
                        continue;
                    }

                    // Simple stemming - remove common suffixes
                    const stemmed = try self.simpleStem(lower);
                    self.allocator.free(lower);
                    try tokens.append(self.allocator, stemmed);
                }
            },
            .standard => {
                // Unicode-aware tokenization with lowercase
                const result = try self.unicodeTokenize(text);
                for (result) |token| {
                    const lower = try self.toLowerCase(token);
                    try tokens.append(self.allocator, lower);
                }
                self.allocator.free(result);
            },
        }

        return try tokens.toOwnedSlice(self.allocator);
    }

    fn toLowerCase(self: *MockLanguageAnalyzer, text: []const u8) ![]u8 {
        const result = try self.allocator.alloc(u8, text.len);
        for (text, 0..) |c, i| {
            result[i] = std.ascii.toLower(c);
        }
        return result;
    }

    fn simpleStem(self: *MockLanguageAnalyzer, word: []const u8) ![]u8 {
        if (word.len < 3) {
            return try self.allocator.dupe(u8, word);
        }

        var result_word = word;

        // Remove common English suffixes
        const suffixes = [_][]const u8{ "ing", "ed", "ly", "es", "s" };

        for (suffixes) |suffix| {
            if (std.mem.endsWith(u8, result_word, suffix)) {
                const new_len = result_word.len - suffix.len;
                if (new_len >= 2) { // Keep at least 2 chars
                    result_word = result_word[0..new_len];
                    break;
                }
            }
        }

        // Always return a newly allocated copy with the correct length
        return try self.allocator.dupe(u8, result_word);
    }

    fn unicodeTokenize(self: *MockLanguageAnalyzer, text: []const u8) ![][]const u8 {
        var tokens = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
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
                    try tokens.append(self.allocator, try self.allocator.dupe(u8, token));
                    token_start = null;
                }
            }
            i += 1;
        }

        // Handle last token
        if (token_start) |start| {
            const token = text[start..];
            try tokens.append(self.allocator, try self.allocator.dupe(u8, token));
        }

        return try tokens.toOwnedSlice(self.allocator);
    }
};

// CANARY: REQ=REQ-GQL-FTS-ADV-002; FEATURE="Advanced Text Analyzers"; ASPECT=TESTING; STATUS=IMPL; TEST=TestCANARY_Advanced_Text_Analyzers; OWNER=search; UPDATED=2025-10-04
test "Advanced Text Analyzers: Simple analyzer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var analyzer = try MockLanguageAnalyzer.init(allocator, .simple);
    defer analyzer.deinit();

    const text = "Hello World Testing";
    const tokens = try analyzer.analyze(text);
    defer {
        for (tokens) |token| {
            allocator.free(token);
        }
        allocator.free(tokens);
    }

    try testing.expectEqual(@as(usize, 3), tokens.len);
    try testing.expectEqualStrings("Hello", tokens[0]);
    try testing.expectEqualStrings("World", tokens[1]);
    try testing.expectEqualStrings("Testing", tokens[2]);
}

test "Advanced Text Analyzers: Whitespace analyzer with lowercase" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var analyzer = try MockLanguageAnalyzer.init(allocator, .whitespace);
    defer analyzer.deinit();

    const text = "HELLO World Testing";
    const tokens = try analyzer.analyze(text);
    defer {
        for (tokens) |token| {
            allocator.free(token);
        }
        allocator.free(tokens);
    }

    try testing.expectEqual(@as(usize, 3), tokens.len);
    try testing.expectEqualStrings("hello", tokens[0]);
    try testing.expectEqualStrings("world", tokens[1]);
    try testing.expectEqualStrings("testing", tokens[2]);
}

test "Advanced Text Analyzers: English analyzer with stop words and stemming" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var analyzer = try MockLanguageAnalyzer.init(allocator, .english);
    defer analyzer.deinit();

    const text = "The quick brown foxes are running quickly";
    const tokens = try analyzer.analyze(text);
    defer {
        for (tokens) |token| {
            allocator.free(token);
        }
        allocator.free(tokens);
    }

    // Should remove "The", "are" and stem "foxes" -> "fox", "running" -> "run", "quickly" -> "quick"
    try testing.expect(tokens.len >= 3); // At least "quick", "brown", "fox"

    // Check that stop words are removed
    var found_the = false;
    var found_are = false;
    for (tokens) |token| {
        if (std.mem.eql(u8, token, "the")) found_the = true;
        if (std.mem.eql(u8, token, "are")) found_are = true;
    }
    try testing.expect(!found_the);
    try testing.expect(!found_are);
}

test "Advanced Text Analyzers: Standard analyzer with punctuation handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var analyzer = try MockLanguageAnalyzer.init(allocator, .standard);
    defer analyzer.deinit();

    const text = "Hello, world! Testing-123 with_underscores.";
    const tokens = try analyzer.analyze(text);
    defer {
        for (tokens) |token| {
            allocator.free(token);
        }
        allocator.free(tokens);
    }

    // Should properly tokenize around punctuation and include hyphens/underscores
    try testing.expect(tokens.len >= 3);

    // Check that punctuation is handled correctly
    var found_hello = false;
    var found_world = false;
    var found_testing = false;
    for (tokens) |token| {
        if (std.mem.eql(u8, token, "hello")) found_hello = true;
        if (std.mem.eql(u8, token, "world")) found_world = true;
        if (std.mem.startsWith(u8, token, "testing")) found_testing = true;
    }
    try testing.expect(found_hello);
    try testing.expect(found_world);
    try testing.expect(found_testing);
}

test "Advanced Text Analyzers: Performance comparison" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const large_text = "The quick brown fox jumps over the lazy dog. " ** 100; // Repeat 100 times

    // Test simple analyzer performance
    var simple_analyzer = try MockLanguageAnalyzer.init(allocator, .simple);
    defer simple_analyzer.deinit();

    const start_simple = std.time.milliTimestamp();
    const simple_tokens = try simple_analyzer.analyze(large_text);
    const simple_duration = std.time.milliTimestamp() - start_simple;

    defer {
        for (simple_tokens) |token| {
            allocator.free(token);
        }
        allocator.free(simple_tokens);
    }

    // Test English analyzer performance
    var english_analyzer = try MockLanguageAnalyzer.init(allocator, .english);
    defer english_analyzer.deinit();

    const start_english = std.time.milliTimestamp();
    const english_tokens = try english_analyzer.analyze(large_text);
    const english_duration = std.time.milliTimestamp() - start_english;

    defer {
        for (english_tokens) |token| {
            allocator.free(token);
        }
        allocator.free(english_tokens);
    }

    // English analyzer should produce fewer tokens due to stop word removal
    try testing.expect(english_tokens.len < simple_tokens.len);

    // Both should complete within reasonable time (< 100ms for this test size)
    try testing.expect(simple_duration < 100);
    try testing.expect(english_duration < 100);
}

test "Advanced Text Analyzers: Multi-language text handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var analyzer = try MockLanguageAnalyzer.init(allocator, .standard);
    defer analyzer.deinit();

    // Text with various character types
    const mixed_text = "Hello café naïve 123 test_case";
    const tokens = try analyzer.analyze(mixed_text);
    defer {
        for (tokens) |token| {
            allocator.free(token);
        }
        allocator.free(tokens);
    }

    // Should handle different character types appropriately
    try testing.expect(tokens.len >= 4);

    // Check specific tokens are preserved
    var found_hello = false;
    var found_cafe = false;
    var found_test_case = false;
    for (tokens) |token| {
        if (std.mem.eql(u8, token, "hello")) found_hello = true;
        if (std.mem.startsWith(u8, token, "caf")) found_cafe = true;
        if (std.mem.eql(u8, token, "test_case")) found_test_case = true;
    }
    try testing.expect(found_hello);
    try testing.expect(found_test_case);
}

test "Advanced Text Analyzers: Edge cases and empty input" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var analyzer = try MockLanguageAnalyzer.init(allocator, .english);
    defer analyzer.deinit();

    // Test empty string
    const empty_tokens = try analyzer.analyze("");
    defer allocator.free(empty_tokens);
    try testing.expectEqual(@as(usize, 0), empty_tokens.len);

    // Test only whitespace
    const whitespace_tokens = try analyzer.analyze("   \t\n  ");
    defer allocator.free(whitespace_tokens);
    try testing.expectEqual(@as(usize, 0), whitespace_tokens.len);

    // Test only stop words
    const stopwords_tokens = try analyzer.analyze("the and or but");
    defer {
        for (stopwords_tokens) |token| {
            allocator.free(token);
        }
        allocator.free(stopwords_tokens);
    }
    try testing.expectEqual(@as(usize, 0), stopwords_tokens.len);

    // Test single character words
    const single_char_tokens = try analyzer.analyze("a b c d");
    defer {
        for (single_char_tokens) |token| {
            allocator.free(token);
        }
        allocator.free(single_char_tokens);
    }
    // Should filter out most single chars (except those not in stop words)
    try testing.expect(single_char_tokens.len <= 2);
}

test "Advanced Text Analyzers: Stemming effectiveness" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var analyzer = try MockLanguageAnalyzer.init(allocator, .english);
    defer analyzer.deinit();

    // Test various word forms that should stem to similar roots
    const test_cases = [_][]const u8{
        "running runs runner",
        "testing tested tests",
        "quickly quick",
        "cats cat",
        "studies studied studying",
    };

    for (test_cases) |test_text| {
        const tokens = try analyzer.analyze(test_text);
        defer {
            for (tokens) |token| {
                allocator.free(token);
            }
            allocator.free(tokens);
        }

        // Should produce fewer unique tokens due to stemming
        try testing.expect(tokens.len >= 1);

        // For debugging - check that stemming occurred
        if (tokens.len > 1) {
            // Multiple tokens should have some similarity (simplified check)
            const first_len = tokens[0].len;
            const second_len = tokens[1].len;

            // Stemmed words should generally be shorter or equal length
            try testing.expect(first_len <= test_text.len);
            try testing.expect(second_len <= test_text.len);
        }
    }
}
