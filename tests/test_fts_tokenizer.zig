const std = @import("std");
const geode = @import("geode");
const tok = geode.index.fts_tokenizer;
const fts = geode.index.fts_storage;

fn findTerm(postings: []fts.TermPosting, term: []const u8) ?fts.TermPosting {
    for (postings) |p| {
        if (std.mem.eql(u8, p.term, term)) return p;
    }
    return null;
}

fn hasTerm(postings: []fts.TermPosting, term: []const u8) bool {
    return findTerm(postings, term) != null;
}

// Case 1: stopword removal + term set.
// "the quick brown fox" -> {quick, brown, fox}; "the" dropped.
test "tokenize drops stopwords and yields unique term set" {
    const a = std.testing.allocator;
    const postings = try tok.tokenize(a, "the quick brown fox", null);
    defer tok.freeTermPostings(a, postings);

    try std.testing.expectEqual(@as(usize, 3), postings.len);
    try std.testing.expect(hasTerm(postings, "quick"));
    try std.testing.expect(hasTerm(postings, "brown"));
    try std.testing.expect(hasTerm(postings, "fox"));
    try std.testing.expect(!hasTerm(postings, "the"));
}

// Case 2: positions are ascending and merged into ONE posting.
// "fox fox fox" -> one posting term="fox" positions {0,1,2}.
test "repeated term merges into one posting with ascending positions" {
    const a = std.testing.allocator;
    const postings = try tok.tokenize(a, "fox fox fox", null);
    defer tok.freeTermPostings(a, postings);

    try std.testing.expectEqual(@as(usize, 1), postings.len);
    const p = postings[0];
    try std.testing.expectEqualStrings("fox", p.term);
    try std.testing.expectEqual(@as(usize, 3), p.positions.len);
    try std.testing.expectEqual(@as(u32, 0), p.positions[0]);
    try std.testing.expectEqual(@as(u32, 1), p.positions[1]);
    try std.testing.expectEqual(@as(u32, 2), p.positions[2]);
    // strictly ascending
    var i: usize = 1;
    while (i < p.positions.len) : (i += 1) {
        try std.testing.expect(p.positions[i] > p.positions[i - 1]);
    }
}

// Case 3: case folding collapses variants into one term.
//
// NOTE on preserving EXISTING behavior: geode's geode_unicode.foldCase is a
// deliberately minimal subset fold. Its switch only folds a handful of
// codepoints (A->a, E->e, É, Å, Greek sigma, sharp-s); it does NOT lowercase
// most ASCII letters (e.g. F, O are passed through unchanged). So "Foo"/"FOO"/
// "foo" do NOT collapse under the real fold — the task's illustrative example
// contradicts fulltext.zig's actual normalize path, and per the task rule we
// follow fulltext.zig. We exercise the collapse with letters foldCase DOES fold:
// 'A'->'a' and 'E'->'e', so "AE", "Ae", "aE", "ae" all normalize to "ae".
test "case fold collapses variants into one term" {
    const a = std.testing.allocator;
    const postings = try tok.tokenize(a, "AE Ae aE ae", null);
    defer tok.freeTermPostings(a, postings);

    try std.testing.expectEqual(@as(usize, 1), postings.len);
    const p = postings[0];
    try std.testing.expectEqualStrings("ae", p.term);
    try std.testing.expectEqual(@as(usize, 4), p.positions.len);
}

// Case 4: field tag is copied into emitted posting.
test "field tag is set on emitted posting" {
    const a = std.testing.allocator;
    const postings = try tok.tokenize(a, "red", "color");
    defer tok.freeTermPostings(a, postings);

    try std.testing.expectEqual(@as(usize, 1), postings.len);
    const p = postings[0];
    try std.testing.expectEqualStrings("red", p.term);
    try std.testing.expect(p.field != null);
    try std.testing.expectEqualStrings("color", p.field.?);
}

// Case 5: punctuation/underscore boundary rule.
// fulltext.zig splits on any char that is NOT alphanumeric and NOT '_'.
// "a_b c-d" -> tokens: "a_b", "c", "d" (underscore kept, '-' splits).
test "punctuation and underscore boundary matches fulltext split rule" {
    const a = std.testing.allocator;
    const postings = try tok.tokenize(a, "a_b c-d", null);
    defer tok.freeTermPostings(a, postings);

    try std.testing.expectEqual(@as(usize, 3), postings.len);
    try std.testing.expect(hasTerm(postings, "a_b"));
    try std.testing.expect(hasTerm(postings, "c"));
    try std.testing.expect(hasTerm(postings, "d"));
}

// Case 6a: empty input -> empty slice.
test "empty input yields empty slice" {
    const a = std.testing.allocator;
    const postings = try tok.tokenize(a, "", null);
    defer tok.freeTermPostings(a, postings);
    try std.testing.expectEqual(@as(usize, 0), postings.len);
}

// Case 6b: all-stopword input -> empty slice.
test "all-stopword input yields empty slice" {
    const a = std.testing.allocator;
    const postings = try tok.tokenize(a, "the a an and of to", null);
    defer tok.freeTermPostings(a, postings);
    try std.testing.expectEqual(@as(usize, 0), postings.len);
}

// Case 6c: only-punctuation input -> empty slice.
test "punctuation-only input yields empty slice" {
    const a = std.testing.allocator;
    const postings = try tok.tokenize(a, "-- ,, ;;", null);
    defer tok.freeTermPostings(a, postings);
    try std.testing.expectEqual(@as(usize, 0), postings.len);
}

// Case 7: positions track the RAW token stream ordinal (pre-stopword removal),
// so phrase alignment is preserved. "the quick the brown" -> raw ordinals
// the=0, quick=1, the=2, brown=3. After dropping stopword "the":
// quick at position 1, brown at position 3.
test "positions use raw token-stream ordinal so phrase alignment is preserved" {
    const a = std.testing.allocator;
    const postings = try tok.tokenize(a, "the quick the brown", null);
    defer tok.freeTermPostings(a, postings);

    try std.testing.expectEqual(@as(usize, 2), postings.len);
    const quick = findTerm(postings, "quick").?;
    const brown = findTerm(postings, "brown").?;
    try std.testing.expectEqual(@as(usize, 1), quick.positions.len);
    try std.testing.expectEqual(@as(u32, 1), quick.positions[0]);
    try std.testing.expectEqual(@as(usize, 1), brown.positions.len);
    try std.testing.expectEqual(@as(u32, 3), brown.positions[0]);
}
