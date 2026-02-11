// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;
const string_search = @import("string_search.zig");

// Helper to check if two slices contain the same elements
fn expectEqualSlices(expected: []const usize, actual: []const usize) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |exp, i| {
        try testing.expectEqual(exp, actual[i]);
    }
}

// ============================================================================
// KMP Tests
// ============================================================================

test "KMP - basic single match" {
    const text = "hello world";
    const pattern = "world";
    const result = try string_search.findAllKMP(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{6}, result);
}

test "KMP - multiple matches" {
    const text = "patternXpatternYpatternZpattern";
    const pattern = "pattern";
    const result = try string_search.findAllKMP(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{ 0, 8, 16, 24 }, result);
}

test "KMP - overlapping matches" {
    const text = "aaaa";
    const pattern = "aa";
    const result = try string_search.findAllKMP(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{ 0, 1, 2 }, result);
}

test "KMP - no matches" {
    const text = "hello world";
    const pattern = "xyz";
    const result = try string_search.findAllKMP(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{}, result);
}

test "KMP - pattern at start" {
    const text = "abcdef";
    const pattern = "abc";
    const result = try string_search.findAllKMP(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{0}, result);
}

test "KMP - pattern at end" {
    const text = "abcdef";
    const pattern = "def";
    const result = try string_search.findAllKMP(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{3}, result);
}

test "KMP - pattern equals text" {
    const text = "exact";
    const pattern = "exact";
    const result = try string_search.findAllKMP(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{0}, result);
}

test "KMP - empty pattern" {
    const text = "hello";
    const pattern = "";
    const result = try string_search.findAllKMP(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{}, result);
}

test "KMP - empty text" {
    const text = "";
    const pattern = "hello";
    const result = try string_search.findAllKMP(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{}, result);
}

test "KMP - pattern longer than text" {
    const text = "hi";
    const pattern = "hello";
    const result = try string_search.findAllKMP(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{}, result);
}

test "KMP - repeated pattern with prefix overlap" {
    const text = "ababababab";
    const pattern = "abab";
    const result = try string_search.findAllKMP(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{ 0, 2, 4, 6 }, result);
}

test "KMP - single character pattern" {
    const text = "abacaba";
    const pattern = "a";
    const result = try string_search.findAllKMP(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{ 0, 2, 4, 6 }, result);
}

test "KMP - complex repeated substring" {
    const text = "AABAACAADAABAABA";
    const pattern = "AABA";
    const result = try string_search.findAllKMP(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{ 0, 9, 12 }, result);
}

// ============================================================================
// Rabin-Karp Tests
// ============================================================================

test "RabinKarp - basic single match" {
    const text = "hello world";
    const pattern = "world";
    const result = try string_search.findAllRabinKarp(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{6}, result);
}

test "RabinKarp - multiple matches" {
    const text = "patternXpatternYpatternZpattern";
    const pattern = "pattern";
    const result = try string_search.findAllRabinKarp(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{ 0, 8, 16, 24 }, result);
}

test "RabinKarp - overlapping matches" {
    const text = "aaaa";
    const pattern = "aa";
    const result = try string_search.findAllRabinKarp(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{ 0, 1, 2 }, result);
}

test "RabinKarp - no matches" {
    const text = "hello world";
    const pattern = "xyz";
    const result = try string_search.findAllRabinKarp(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{}, result);
}

test "RabinKarp - pattern at start" {
    const text = "abcdef";
    const pattern = "abc";
    const result = try string_search.findAllRabinKarp(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{0}, result);
}

test "RabinKarp - pattern at end" {
    const text = "abcdef";
    const pattern = "def";
    const result = try string_search.findAllRabinKarp(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{3}, result);
}

test "RabinKarp - pattern equals text" {
    const text = "exact";
    const pattern = "exact";
    const result = try string_search.findAllRabinKarp(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{0}, result);
}

test "RabinKarp - empty pattern" {
    const text = "hello";
    const pattern = "";
    const result = try string_search.findAllRabinKarp(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{}, result);
}

test "RabinKarp - empty text" {
    const text = "";
    const pattern = "hello";
    const result = try string_search.findAllRabinKarp(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{}, result);
}

test "RabinKarp - pattern longer than text" {
    const text = "hi";
    const pattern = "hello";
    const result = try string_search.findAllRabinKarp(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{}, result);
}

test "RabinKarp - repeated pattern with prefix overlap" {
    const text = "ababababab";
    const pattern = "abab";
    const result = try string_search.findAllRabinKarp(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{ 0, 2, 4, 6 }, result);
}

test "RabinKarp - single character pattern" {
    const text = "abacaba";
    const pattern = "a";
    const result = try string_search.findAllRabinKarp(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{ 0, 2, 4, 6 }, result);
}

test "RabinKarp - complex repeated substring" {
    const text = "AABAACAADAABAABA";
    const pattern = "AABA";
    const result = try string_search.findAllRabinKarp(testing.allocator, text, pattern);
    defer testing.allocator.free(result);

    try expectEqualSlices(&[_]usize{ 0, 9, 12 }, result);
}

// ============================================================================
// Algorithm Parity Tests (KMP vs Rabin-Karp)
// ============================================================================

test "Parity - both algorithms produce same results" {
    const test_cases = [_]struct {
        text: []const u8,
        pattern: []const u8,
    }{
        .{ .text = "hello world hello", .pattern = "hello" },
        .{ .text = "aaaaaaa", .pattern = "aaa" },
        .{ .text = "abcabcabc", .pattern = "abc" },
        .{ .text = "no match here", .pattern = "xyz" },
        .{ .text = "ABABDABACDABABCABAB", .pattern = "ABABCABAB" },
    };

    for (test_cases) |tc| {
        const kmp_result = try string_search.findAllKMP(testing.allocator, tc.text, tc.pattern);
        defer testing.allocator.free(kmp_result);

        const rk_result = try string_search.findAllRabinKarp(testing.allocator, tc.text, tc.pattern);
        defer testing.allocator.free(rk_result);

        try expectEqualSlices(kmp_result, rk_result);
    }
}

// ============================================================================
// Acceptance Test (from Go implementation)
// ============================================================================

test "Acceptance - string search algorithms" {
    const text = "patternXpatternYpatternZpattern";
    const pattern = "pattern";
    const expected = [_]usize{ 0, 8, 16, 24 };

    const kmp = try string_search.findAllKMP(testing.allocator, text, pattern);
    defer testing.allocator.free(kmp);
    try expectEqualSlices(&expected, kmp);

    const rk = try string_search.findAllRabinKarp(testing.allocator, text, pattern);
    defer testing.allocator.free(rk);
    try expectEqualSlices(&expected, rk);
}
