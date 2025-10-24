const std = @import("std");

// Knuth–Morris–Pratt string search (ASCII / arbitrary bytes). Provides:
//  - buildFailure(pattern)
//  - findFirst(haystack, pattern)
//  - findAll(haystack, pattern, out allocator)
// Complexity: O(n + m).
// Deterministic, allocation-free for single search (except optional all-matches output storage).
//
// CANARY: REQ=REQ-GQL-070; FEATURE="String Search"; ASPECT=KMP; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_070_KMP; BENCH=BenchmarkCANARY_REQ_GQL_070_KMP; OWNER=graph; UPDATED=2025-09-21

pub const Kmp = struct {
    pub fn buildFailure(alloc: std.mem.Allocator, pat: []const u8) ![]usize {
        var fail = try alloc.alloc(usize, pat.len);
        if (pat.len == 0) return fail; // zero-length pattern (unused sentinel)
        fail[0] = 0;
        var len: usize = 0;
        var i: usize = 1;
        while (i < pat.len) : (i += 1) {
            if (pat[i] == pat[len]) {
                len += 1;
                fail[i] = len;
            } else if (len != 0) {
                len = fail[len - 1];
                i -= 1; // retry with shorter prefix
            } else {
                fail[i] = 0;
            }
        }
        return fail;
    }

    pub fn findFirst(h: []const u8, p: []const u8, fail: []const usize) ?usize {
        if (p.len == 0) return 0; // define empty pattern found at start
        var i: usize = 0; // haystack idx
        var j: usize = 0; // pattern idx
        while (i < h.len) : (i += 1) {
            while (j > 0 and p[j] != h[i]) j = fail[j - 1];
            if (p[j] == h[i]) j += 1;
            if (j == p.len) return i + 1 - p.len;
        }
        return null;
    }

    pub fn findAll(alloc: std.mem.Allocator, h: []const u8, p: []const u8, fail: []const usize) ![]usize {
        var out = std.ArrayList(usize).init(alloc);
        if (p.len == 0) return alloc.alloc(usize, 0);
        var i: usize = 0;
        var j: usize = 0;
        while (i < h.len) : (i += 1) {
            while (j > 0 and p[j] != h[i]) j = fail[j - 1];
            if (p[j] == h[i]) j += 1;
            if (j == p.len) {
                try out.append(i + 1 - p.len);
                j = fail[j - 1]; // allow overlaps
            }
        }
        return out.toOwnedSlice();
    }
};

test "kmp basic" {
    const ally = std.testing.allocator;
    const pat = "aba";
    const txt = "abacaba";
    const fail = try Kmp.buildFailure(ally, pat);
    defer ally.free(fail);
    const first = Kmp.findFirst(txt, pat, fail).?;
    try std.testing.expect(first == 0);
    const all = try Kmp.findAll(ally, txt, pat, fail);
    defer ally.free(all);
    try std.testing.expect(all.len == 2 and all[0] == 0 and all[1] == 4);
}
