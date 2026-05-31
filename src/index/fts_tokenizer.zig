const std = @import("std");
const fts = @import("fts_storage_lib");
// Named-module import (not a sibling path): a module rooted at src/index/ may not
// path-import ../unicode/*, so build.zig wires geode_unicode.zig as the named
// module "geode_unicode". geode_unicode imports only std, so the module is
// self-contained (no further addImport needed).
const geode_unicode = @import("geode_unicode");

// CANARY: REQ=REQ-GQL-FTS-002; FEATURE="FTS Tokenizer"; ASPECT=Tokenize; STATUS=TESTED; TEST=test_fts_tokenizer; OWNER=index; UPDATED=2026-05-30
//
// Standalone full-text tokenizer producing fts_storage TermPostings.
//
// Behavior preserved EXACTLY from src/index/fulltext.zig:
//   - Token boundary: a token is a maximal run of characters c where
//     `std.ascii.isAlphanumeric(c) or c == '_'`. Any other byte is a separator.
//     (fulltext.zig `tokenize`, ~lines 177-202.)
//   - Position numbering: each token's ordinal is its index in the RAW token
//     stream (0,1,2,...) assigned BEFORE stopword removal, matching the
//     `Token.position = tokens.items.len` assignment in fulltext.zig. Phrase
//     alignment therefore survives stopword filtering.
//   - Stopwords: the same 24-word English set from fulltext.zig (init, ~lines
//     59-63). fulltext.zig's `search` (~line 117) tests the RAW token text
//     (`self.stopwords.contains(token.text)`) BEFORE normalization, so we do the
//     same: the stopword check runs on the raw token bytes. For the all-lowercase
//     ASCII stopword set this is equivalent to a post-normalize check, but we
//     mirror the actual source to avoid drift.
//   - Normalize: NFC then case fold, via geode_unicode.nfcNormalize +
//     geode_unicode.foldCase, identical to fulltext.zig `normalize`
//     (~lines 204-212). A token that normalizes to empty is dropped.
//   - Grouping: positions per unique normalized term are accumulated, then ONE
//     TermPosting{ term, positions, field } is emitted per term with positions
//     sorted strictly ascending (the fts_storage lib rejects non-monotonic
//     positions and one-posting-per-term).
//
// Memory: the result outlives all scratch state; every term, positions slice,
// and (non-null) field is duped with `allocator`. `field` is duped per posting
// so freeTermPostings can free each posting's field independently with no
// double-free. Free with freeTermPostings.

// The English stopword set. Copied verbatim from src/index/fulltext.zig init
// (the 24 words there). Compared against the RAW token bytes, matching
// fulltext.zig's search-time `self.stopwords.contains(token.text)`.
const stopwords = [_][]const u8{
    "a",    "an",  "and", "are", "as",   "at",   "be",  "by", "for",
    "from", "has", "he",  "in",  "is",   "it",   "its", "of", "on",
    "that", "the", "to",  "was", "will", "with",
};

fn isStopword(token: []const u8) bool {
    for (stopwords) |w| {
        if (std.mem.eql(u8, w, token)) return true;
    }
    return false;
}

/// Tokenize `text` into fts_storage TermPostings: split -> normalize (NFC +
/// case-fold) -> drop stopwords -> group by term with ascending ordinal
/// positions. `field` is copied into every emitted TermPosting (caller sets it
/// to the property name, or null). Caller owns the result; free with
/// freeTermPostings.
pub fn tokenize(allocator: std.mem.Allocator, text: []const u8, field: ?[]const u8) ![]fts.TermPosting {
    // Accumulate positions per unique normalized term. Insertion order is
    // preserved via `order` so output is deterministic (first-seen order).
    var groups = std.StringHashMap(std.ArrayListUnmanaged(u32)).init(allocator);
    defer {
        var it = groups.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        groups.deinit();
    }

    var order: std.ArrayListUnmanaged([]const u8) = .empty;
    defer order.deinit(allocator);

    var raw_ordinal: u32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        // Skip separators (anything not alphanumeric and not '_').
        while (i < text.len and !(std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) : (i += 1) {}
        if (i >= text.len) break;

        const start = i;
        while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) : (i += 1) {}
        if (i <= start) continue; // defensive; not reachable

        const raw = text[start..i];
        const position = raw_ordinal;
        raw_ordinal += 1;

        // Stopword check on the RAW token bytes (matches fulltext.zig search).
        if (isStopword(raw)) continue;

        // Normalize: NFC then case fold (matches fulltext.zig normalize).
        const nfc = try geode_unicode.nfcNormalize(allocator, raw);
        defer allocator.free(nfc);
        const folded = try geode_unicode.foldCase(allocator, nfc);
        defer allocator.free(folded);

        if (folded.len == 0) continue; // dropped: normalizes to empty

        const gop = try groups.getOrPut(folded);
        if (!gop.found_existing) {
            // Dupe the key so it survives `folded` being freed; record order.
            const key = try allocator.dupe(u8, folded);
            gop.key_ptr.* = key;
            gop.value_ptr.* = .empty;
            try order.append(allocator, key);
        }
        try gop.value_ptr.append(allocator, position);
    }

    if (order.items.len == 0) return &[_]fts.TermPosting{};

    var result = try allocator.alloc(fts.TermPosting, order.items.len);
    var built: usize = 0;
    errdefer {
        for (result[0..built]) |p| {
            allocator.free(p.term);
            allocator.free(p.positions);
            if (p.field) |f| allocator.free(f);
        }
        allocator.free(result);
    }

    for (order.items) |key| {
        const positions_list = groups.getPtr(key).?;
        // Positions are appended in raw-stream order, hence already strictly
        // ascending; sort defensively to satisfy the fts_storage contract.
        const positions = try allocator.dupe(u32, positions_list.items);
        std.mem.sort(u32, positions, {}, std.sort.asc(u32));

        const term_copy = try allocator.dupe(u8, key);
        errdefer {
            allocator.free(term_copy);
            allocator.free(positions);
        }

        var field_copy: ?[]const u8 = null;
        if (field) |f| {
            field_copy = try allocator.dupe(u8, f);
        }

        result[built] = .{ .term = term_copy, .positions = positions, .field = field_copy };
        built += 1;
    }

    return result;
}

/// Free a slice returned by `tokenize`. Frees each term, each positions slice,
/// each non-null field, and the outer slice.
pub fn freeTermPostings(allocator: std.mem.Allocator, postings: []fts.TermPosting) void {
    for (postings) |p| {
        allocator.free(p.term);
        allocator.free(p.positions);
        if (p.field) |f| allocator.free(f);
    }
    if (postings.len > 0) allocator.free(postings);
}
