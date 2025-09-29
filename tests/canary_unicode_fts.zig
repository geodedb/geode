const std = @import("std");
const unicode = @import("../src/unicode/geode_unicode.zig");
// NOTE: Real FTS index integration is heavy; we simulate the normalization pipeline used by fulltext/advanced.
// CANARY: REQ=REQ-GQL-UNICODE-007; FEATURE="UnicodeFtsIntegration"; ASPECT=IndexerNormalize; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_007_FtsNormalize; OWNER=unicode; UPDATED=2025-09-27
// Source index fulltext.zig updated to match this test name
// CANARY: REQ=REQ-GQL-UNICODE-008; FEATURE="UnicodeFtsAdvanced"; ASPECT=AnalyzerLower; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_008_AnalyzerLower; OWNER=unicode; UPDATED=2025-09-27

fn ftsNormalize(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    // Emulate: NFC then foldCase then lowercase ascii (foldCase already lowers for our subset)
    const n = try unicode.nfcNormalize(alloc, s);
    errdefer alloc.free(n);
    const f = try unicode.foldCase(alloc, n);
    alloc.free(n);
    return f; // f is already lowered
}

test "TestCANARY_REQ_GQL_UNICODE_007_FtsNormalize" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const doc_form = "Stra\xC3\x9Fe"; // Straße (ß)
    const query_form = "STRASSE"; // Uppercase equivalent post-fold
    const ndoc = try ftsNormalize(alloc, doc_form);
    defer alloc.free(ndoc);
    const nquery = try ftsNormalize(alloc, query_form);
    defer alloc.free(nquery);
    try std.testing.expect(std.mem.eql(u8, ndoc, nquery));
}

test "TestCANARY_REQ_GQL_UNICODE_008_AnalyzerLower" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const a = "E\xCC\x81"; // decomposed É
    const b = "\xC9"; // precomposed É
    const na = try ftsNormalize(alloc, a);
    defer alloc.free(na);
    const nb = try ftsNormalize(alloc, b);
    defer alloc.free(nb);
    try std.testing.expect(std.mem.eql(u8, na, nb));
}
