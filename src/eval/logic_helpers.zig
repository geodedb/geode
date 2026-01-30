// CANARY: REQ=REQ-REFACTOR-EVAL-001; FEATURE="EvalRefactoring"; ASPECT=LogicHelpers; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
/// Logic and regex helper functions extracted from eval.zig
/// Contains three-valued logic, regex matching, and pattern helpers
const std = @import("std");
const value_types = @import("../value_types.zig");
const Value = value_types.Value;

// ============================================================================
// Three-valued Logic Functions
// ============================================================================

pub fn and3(a: Value, b: Value) Value {
    // Three-valued logic for AND: true ∧ x = x; false ∧ x = false; null ∧ true = null; null ∧ false = false; null ∧ null = null
    if (a == .Bool and !a.Bool) return .{ .Bool = false };
    if (b == .Bool and !b.Bool) return .{ .Bool = false };
    if (a == .Bool and a.Bool and b == .Bool) return .{ .Bool = b.Bool };
    if (b == .Bool and b.Bool and a == .Bool) return .{ .Bool = a.Bool };
    if (a == .Null or b == .Null) return Value{ .Null = {} };
    // Non-bool values treated as false for now
    return .{ .Bool = false };
}

pub fn or3(a: Value, b: Value) Value {
    // Three-valued logic for OR: true ∨ x = true; false ∨ x = x; null ∨ true = true; null ∨ false = null; null ∨ null = null
    if (a == .Bool and a.Bool) return .{ .Bool = true };
    if (b == .Bool and b.Bool) return .{ .Bool = true };
    if (a == .Bool and !a.Bool and b == .Bool) return .{ .Bool = b.Bool };
    if (b == .Bool and !b.Bool and a == .Bool) return .{ .Bool = a.Bool };
    if (a == .Null or b == .Null) return Value{ .Null = {} };
    return .{ .Bool = false };
}

pub fn xor3(a: Value, b: Value) Value {
    // Three-valued logic for XOR: returns true when exactly one operand is true
    // null XOR anything = null
    if (a == .Null or b == .Null) return Value{ .Null = {} };

    // Both must be Bool for XOR to work
    if (a == .Bool and b == .Bool) {
        return .{ .Bool = a.Bool != b.Bool };
    }

    // Non-bool values treated as false
    return .{ .Bool = false };
}

// ============================================================================
// Regex Helper Functions
// ============================================================================

pub fn regexEatEsc(pat: []const u8, idx: *usize) ?u8 {
    if (idx.* >= pat.len) return null;
    const c = pat[idx.*];
    idx.* += 1;
    return c;
}

pub fn regexMatchClass(ch: u8, pat: []const u8, idx: *usize) bool {
    var i = idx.*;
    var neg = false;
    if (i < pat.len and pat[i] == '^') {
        neg = true;
        i += 1;
    }
    var hit = false;
    while (i < pat.len and pat[i] != ']') : (i += 1) {
        if (i + 2 < pat.len and pat[i + 1] == '-') {
            const start = pat[i];
            const endc = pat[i + 2];
            if (start <= ch and ch <= endc) hit = true;
            i += 2;
            continue;
        }
        if (pat[i] == ch) hit = true;
    }
    idx.* = i; // now at closing ']' (or end)
    return if (neg) !hit else hit;
}

// CANARY: REQ=REQ-GQL-REGEX-FIX-001; FEATURE="RegexMatching"; ASPECT=OverflowPrevention; STATUS=TESTED; TEST=geodetestlab/specs/test_regex.yml; OWNER=eval; UPDATED=2026-01-09
// Fixed integer overflow in greedy matching loops by using k+1 start and pre-decrement
// Added support for [class]* quantifier pattern
pub fn regexRec(s: []const u8, p: []const u8, si0: usize, pi0: usize, allow_suffix_end: bool) bool {
    var si = si0;
    var pi = pi0;
    while (pi < p.len) {
        const pc = p[pi];
        if (pc == '.') {
            if (pi + 1 < p.len and p[pi + 1] == '*') {
                // Match .* - zero or more of any character (greedy)
                // Try matching from longest to shortest to handle greedy semantics
                // Use k+1 starting point to avoid underflow when decrementing
                var k: usize = s.len + 1;
                while (k > si) {
                    k -= 1;
                    if (regexRec(s, p, k, pi + 2, allow_suffix_end)) return true;
                }
                return false;
            }
            if (si >= s.len) return false;
            si += 1;
            pi += 1;
            continue;
        } else if (pc == '[') {
            var i: usize = pi + 1;
            while (i < p.len and p[i] != ']') : (i += 1) {}
            if (i >= p.len) return false;
            const class_end = i + 1; // Position after ']'

            // Check for quantifiers after character class
            if (class_end < p.len and p[class_end] == '*') {
                // [class]* - match zero or more characters from class (greedy)
                // Find how far we can extend matching the class
                var match_end = si;
                while (match_end < s.len) {
                    var check_idx: usize = pi + 1;
                    if (!regexMatchClass(s[match_end], p, &check_idx)) break;
                    match_end += 1;
                }
                // Try matching from longest to shortest
                var k: usize = match_end + 1;
                while (k > si) {
                    k -= 1;
                    if (regexRec(s, p, k, class_end + 1, allow_suffix_end)) return true;
                }
                return false;
            }

            if (si >= s.len) return false;
            var idx: usize = pi + 1;
            if (!regexMatchClass(s[si], p, &idx)) return false;
            if (class_end < p.len and p[class_end] == '?') {
                if (regexRec(s, p, si, class_end + 1, allow_suffix_end)) return true;
            }
            si += 1;
            const opt_inc: usize = if (class_end < p.len and p[class_end] == '?') @as(usize, 1) else 0;
            pi = class_end + opt_inc;
            continue;
        } else if (pc == '\\') {
            var idx: usize = pi + 1;
            const lit = regexEatEsc(p, &idx) orelse return false;
            if (si >= s.len or s[si] != lit) return false;
            si += 1;
            pi = idx;
            continue;
        } else if (pc == '?') {
            return false;
        } else {
            if (pi + 1 < p.len and p[pi + 1] == '?') {
                if (regexRec(s, p, si, pi + 2, allow_suffix_end)) return true;
                if (si >= s.len or s[si] != pc) return false;
                si += 1;
                pi += 2;
                continue;
            }
            if (si >= s.len or s[si] != pc) return false;
            si += 1;
            pi += 1;
        }
    }
    return allow_suffix_end or si == s.len;
}

// ============================================================================
// Pattern Matching Helpers
// ============================================================================

pub fn transformPlusQuantifier(pattern: []const u8, buf: *[256]u8) ![]const u8 {
    // Transform [class]+ to [class][class]* for simpler matching
    // This handles the + quantifier by expanding it to equivalent form
    var write_idx: usize = 0;
    var i: usize = 0;

    while (i < pattern.len) {
        if (pattern[i] == '[') {
            // Find the closing ]
            var j = i + 1;
            while (j < pattern.len and pattern[j] != ']') : (j += 1) {}

            if (j < pattern.len) {
                // Found complete character class
                const class_end = j + 1;

                // Check if followed by +
                if (class_end < pattern.len and pattern[class_end] == '+') {
                    // Transform [class]+ to [class][class]*
                    const class_len = class_end - i; // Length of [class] including ]
                    if (write_idx + class_len * 2 + 1 >= buf.len) return error.BufferTooSmall;

                    // First copy: [class] - matches at least one
                    @memcpy(buf[write_idx .. write_idx + class_len], pattern[i..class_end]);
                    write_idx += class_len;

                    // Second copy: [class]* - matches zero or more additional
                    @memcpy(buf[write_idx .. write_idx + class_len], pattern[i..class_end]);
                    write_idx += class_len;
                    buf[write_idx] = '*'; // Append * after the ]
                    write_idx += 1;

                    i = class_end + 1; // Skip past the +
                } else {
                    // No +, copy as-is
                    if (write_idx + class_end - i >= buf.len) return error.BufferTooSmall;
                    @memcpy(buf[write_idx .. write_idx + (class_end - i)], pattern[i..class_end]);
                    write_idx += class_end - i;
                    i = class_end;
                }
            } else {
                // Incomplete class, copy what we have
                if (write_idx >= buf.len) return error.BufferTooSmall;
                buf[write_idx] = pattern[i];
                write_idx += 1;
                i += 1;
            }
        } else {
            // Regular character, copy as-is
            if (write_idx >= buf.len) return error.BufferTooSmall;
            buf[write_idx] = pattern[i];
            write_idx += 1;
            i += 1;
        }
    }

    return buf[0..write_idx];
}

pub fn matchSimplePattern(s: []const u8, p_in: []const u8) bool {
    // Lightweight matcher: ^, $, ., .*, [..], escapes, '?' (no alternation)
    // Transform + to equivalent pattern first
    var buf: [256]u8 = undefined;
    const p_transformed = transformPlusQuantifier(p_in, &buf) catch p_in;

    if (p_transformed.len == 0) return s.len == 0; // empty pattern matches empty string only
    var p = p_transformed;
    var anchor_start = false;
    var anchor_end = false;
    if (p.len > 0 and p[0] == '^') {
        anchor_start = true;
        p = p[1..];
    }
    // Lightweight matcher: ^, $, ., .*, [..], escapes, '?' (no alternation)
    if (p.len > 0 and p[p.len - 1] == '$') {
        anchor_end = true;
        p = p[0 .. p.len - 1];
    }
    // Trivial wildcard-only pattern: ".*" or "" after removing anchors
    if (p.len == 0) return !anchor_start or !anchor_end or s.len == 0; // "^$" matches empty only
    if (p.len == 2 and p[0] == '.' and p[1] == '*') return true;

    const allow_suffix_end = !anchor_end;
    if (anchor_start) return regexRec(s, p, 0, 0, allow_suffix_end);
    var start: usize = 0;
    while (start <= s.len) : (start += 1) if (regexRec(s, p, start, 0, allow_suffix_end)) return true;
    return false;
}
