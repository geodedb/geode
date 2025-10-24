const std = @import("std");
const unicode = @import("../unicode/geode_unicode.zig");
// CANARY: REQ=REQ-GQL-UNICODE-004; FEATURE="UnicodeCore"; ASPECT=NormalizationNfc; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_004_NfcRoundTrip; OWNER=unicode; UPDATED=2025-09-27
// CANARY: REQ=REQ-GQL-UNICODE-005; FEATURE="UnicodeCore"; ASPECT=CaseFolding; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_005_FoldSharpS; OWNER=unicode; UPDATED=2025-09-27

test "TestCANARY_REQ_GQL_UNICODE_004_NfcRoundTrip" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const input = "E\xCC\x81 and e\xCC\x81"; // E + combining acute, e + combining acute
    const norm = try unicode.nfcNormalize(alloc, input);
    defer alloc.free(norm);
    try std.testing.expect(std.mem.indexOf(u8, norm, "\xC9") != null); // É
    try std.testing.expect(std.mem.indexOf(u8, norm, "\xC3\xA9") != null); // é
}

test "TestCANARY_REQ_GQL_UNICODE_005_FoldSharpS" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const input = "Stra\xC3\x9Fe"; // Straße
    const folded = try unicode.foldCase(alloc, input);
    defer alloc.free(folded);
    try std.testing.expect(std.mem.indexOf(u8, folded, "strasse") != null);
}
