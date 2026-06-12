//! Public Suffix List (PSL) evaluation - eTLD+1 / registrable domain.
//!
//! CANARY: REQ=REQ-GQL-DOMAIN-ROOT-001; FEATURE="DomainRoot"; ASPECT=PublicSuffix; STATUS=TESTED; TEST=tests/test_gap0877_advanced_types.zig; OWNER=types; UPDATED=2026-06-11
//!
//! GAP-0877: `domain_root(domain)` previously returned the last two labels
//! unconditionally, which is wrong for multi-label registry suffixes
//! (e.g. `a.b.example.co.uk` must root to `example.co.uk`, not `co.uk`).
//! This module implements the publicsuffix.org algorithm against a bundled,
//! TRIMMED snapshot of the Public Suffix List
//! (`src/types/data/public_suffix_list.dat` - see its attribution header).
//!
//! Rules (per https://publicsuffix.org/list/):
//! - A rule matches a domain when, comparing labels right-to-left, every rule
//!   label equals the corresponding domain label ("*" matches any label).
//! - An exception rule ("!" prefix) prevails over all other matching rules;
//!   its public suffix is the rule with the leftmost label removed.
//! - Otherwise the prevailing rule is the matching rule with the most labels.
//! - If no rule matches, the prevailing rule is "*" (public suffix = last
//!   label), so unknown TLDs fall back to a last-two-labels registrable
//!   domain.

const std = @import("std");

const psl_data = @embedFile("data/public_suffix_list.dat");

/// Number of labels in the public suffix of `labels` per the PSL algorithm.
/// `labels` are the domain labels in left-to-right order (already lowercase
/// in Geode's `url.Domain`, but matching is case-insensitive anyway).
pub fn publicSuffixLabelCount(labels: []const []const u8) usize {
    if (labels.len == 0) return 0;

    var best: usize = 1; // implicit default rule "*"
    var lines = std.mem.tokenizeAny(u8, psl_data, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "//")) continue;

        const is_exception = line[0] == '!';
        const rule = if (is_exception) line[1..] else line;
        const matched = ruleMatchLabelCount(rule, labels) orelse continue;

        if (is_exception) {
            // Exception rules always prevail; the public suffix is the rule
            // minus its leftmost label.
            return matched - 1;
        }
        if (matched > best) best = matched;
    }
    return best;
}

/// Match `rule` (dot-separated, may contain "*" labels) against the domain
/// labels right-to-left. Returns the number of rule labels on match.
fn ruleMatchLabelCount(rule: []const u8, labels: []const []const u8) ?usize {
    var count: usize = 0;
    var counter = std.mem.splitScalar(u8, rule, '.');
    while (counter.next()) |_| count += 1;
    if (count == 0 or count > labels.len) return null;

    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, rule, '.');
    while (it.next()) |rule_label| : (idx += 1) {
        if (std.mem.eql(u8, rule_label, "*")) continue;
        const domain_label = labels[labels.len - count + idx];
        if (!std.ascii.eqlIgnoreCase(rule_label, domain_label)) return null;
    }
    return count;
}

/// Registrable domain (eTLD+1) for the given domain labels, allocated with
/// `allocator`. Returns null when the domain itself is (or is shorter than)
/// a public suffix - such a domain has no registrable part.
pub fn registrableDomain(
    allocator: std.mem.Allocator,
    labels: []const []const u8,
) error{OutOfMemory}!?[]u8 {
    if (labels.len == 0) return null;
    const ps_count = publicSuffixLabelCount(labels);
    if (labels.len <= ps_count) return null;
    return try std.mem.join(allocator, ".", labels[labels.len - ps_count - 1 ..]);
}

test "publicSuffixLabelCount: exact multi-label rule" {
    try std.testing.expectEqual(
        @as(usize, 2),
        publicSuffixLabelCount(&.{ "example", "co", "uk" }),
    );
}

test "publicSuffixLabelCount: unknown TLD falls back to default rule" {
    try std.testing.expectEqual(
        @as(usize, 1),
        publicSuffixLabelCount(&.{ "foo", "bar", "unknowntld" }),
    );
}

test "publicSuffixLabelCount: wildcard rule *.ck" {
    try std.testing.expectEqual(
        @as(usize, 2),
        publicSuffixLabelCount(&.{ "a", "b", "ck" }),
    );
}

test "publicSuffixLabelCount: exception rule !www.ck" {
    try std.testing.expectEqual(
        @as(usize, 1),
        publicSuffixLabelCount(&.{ "www", "ck" }),
    );
}

test "registrableDomain: eTLD+1 basics" {
    const allocator = std.testing.allocator;

    const r1 = (try registrableDomain(allocator, &.{ "a", "b", "example", "co", "uk" })).?;
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("example.co.uk", r1);

    const r2 = (try registrableDomain(allocator, &.{ "x", "example", "com" })).?;
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("example.com", r2);

    const r3 = (try registrableDomain(allocator, &.{ "example", "com" })).?;
    defer allocator.free(r3);
    try std.testing.expectEqualStrings("example.com", r3);

    // A bare public suffix has no registrable domain.
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try registrableDomain(allocator, &.{"com"}),
    );
}
