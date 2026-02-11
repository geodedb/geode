// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

/// KMP (Knuth-Morris-Pratt) substring search algorithm
/// Returns all starting indices of pattern occurrences in text
/// Time complexity: O(n + m) where n = text length, m = pattern length
/// Space complexity: O(m) for the LPS table
pub fn findAllKMP(allocator: Allocator, text: []const u8, pattern: []const u8) ![]usize {
    if (pattern.len == 0 or text.len == 0 or pattern.len > text.len) {
        return &[_]usize{};
    }

    // Build LPS (Longest Prefix Suffix) table
    const lps = try buildLPS(allocator, pattern);
    defer allocator.free(lps);

    var result: std.ArrayListUnmanaged(usize) = .{};
    errdefer result.deinit(allocator);

    var i: usize = 0; // text index
    var j: usize = 0; // pattern index

    while (i < text.len) {
        if (text[i] == pattern[j]) {
            i += 1;
            j += 1;

            if (j == pattern.len) {
                // Found a match
                try result.append(allocator, i - j);
                j = lps[j - 1];
            }
        } else {
            if (j != 0) {
                j = lps[j - 1];
            } else {
                i += 1;
            }
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Build the LPS (Longest Prefix Suffix) table for KMP
fn buildLPS(allocator: Allocator, pattern: []const u8) ![]usize {
    const lps = try allocator.alloc(usize, pattern.len);
    errdefer allocator.free(lps);

    lps[0] = 0;
    var len: usize = 0; // length of previous longest prefix suffix
    var i: usize = 1;

    while (i < pattern.len) {
        if (pattern[i] == pattern[len]) {
            len += 1;
            lps[i] = len;
            i += 1;
        } else {
            if (len != 0) {
                len = lps[len - 1];
            } else {
                lps[i] = 0;
                i += 1;
            }
        }
    }

    return lps;
}

/// Rabin-Karp multiple pattern matching with rolling hash
/// Returns all starting indices of pattern occurrences in text
/// Uses base 256 and prime modulus 1000000007
/// Time complexity: O(n + m) average case, O(nm) worst case
/// Space complexity: O(k) where k is the number of matches
pub fn findAllRabinKarp(allocator: Allocator, text: []const u8, pattern: []const u8) ![]usize {
    if (pattern.len == 0 or pattern.len > text.len) {
        return &[_]usize{};
    }

    const base: i64 = 256;
    const mod: i64 = 1000000007; // large prime
    const m = pattern.len;
    const n = text.len;

    // Compute base^(m-1) % mod
    var power: i64 = 1;
    var i: usize = 0;
    while (i < m - 1) : (i += 1) {
        power = @mod(power * base, mod);
    }

    // Compute hash of pattern and first window of text
    var h_pattern: i64 = 0;
    var h_window: i64 = 0;

    i = 0;
    while (i < m) : (i += 1) {
        h_pattern = @mod(h_pattern * base + @as(i64, pattern[i]), mod);
        h_window = @mod(h_window * base + @as(i64, text[i]), mod);
    }

    var result: std.ArrayListUnmanaged(usize) = .{};
    errdefer result.deinit(allocator);

    // Slide the window over text
    i = 0;
    while (i <= n - m) : (i += 1) {
        // If hashes match, verify with character-by-character comparison
        if (h_pattern == h_window) {
            var match = true;
            var j: usize = 0;
            while (j < m) : (j += 1) {
                if (text[i + j] != pattern[j]) {
                    match = false;
                    break;
                }
            }
            if (match) {
                try result.append(allocator, i);
            }
        }

        // Compute hash for next window (rolling hash)
        if (i < n - m) {
            // Remove leading character
            const lead = @mod(@as(i64, text[i]) * power, mod);
            h_window = @mod(h_window - lead + mod, mod);

            // Add trailing character
            h_window = @mod(h_window * base + @as(i64, text[i + m]), mod);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Boyer-Moore string search algorithm with bad character heuristic.
/// Time complexity: O(n/m) best case, O(nm) worst case
/// Space complexity: O(256) for the bad character table
pub fn findAllBoyerMoore(allocator: Allocator, text: []const u8, pattern: []const u8) ![]usize {
    if (pattern.len == 0 or pattern.len > text.len) {
        return &[_]usize{};
    }

    const m = pattern.len;
    const n = text.len;

    // Build bad character table (last occurrence of each character in pattern)
    var bad_char: [256]i64 = undefined;
    for (&bad_char) |*bc| {
        bc.* = -1;
    }
    for (pattern, 0..) |c, i| {
        bad_char[c] = @intCast(i);
    }

    var result: std.ArrayListUnmanaged(usize) = .{};
    errdefer result.deinit(allocator);

    var s: usize = 0; // shift of pattern
    while (s <= n - m) {
        var j: i64 = @intCast(m - 1);

        // Compare pattern from right to left
        while (j >= 0 and pattern[@intCast(j)] == text[s + @as(usize, @intCast(j))]) {
            j -= 1;
        }

        if (j < 0) {
            // Pattern found
            try result.append(allocator, s);

            // Shift pattern to align next occurrence
            if (s + m < n) {
                const shift = m - 1 - @as(usize, @intCast(@max(0, bad_char[text[s + m]])));
                s += if (shift == 0) 1 else shift;
            } else {
                s += 1;
            }
        } else {
            // Shift based on bad character heuristic
            const bc = bad_char[text[s + @as(usize, @intCast(j))]];
            const shift = j - bc;
            s += @intCast(@max(1, shift));
        }
    }

    return result.toOwnedSlice(allocator);
}
