const std = @import("std");
const unicode = @import("../src/unicode/geode_unicode.zig");
// CANARY: REQ=REQ-GQL-UNICODE-010; FEATURE="UnicodeOrderBy"; ASPECT=CompareNfc; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_010_OrderByNfc; OWNER=unicode; UPDATED=2025-09-27

test "TestCANARY_REQ_GQL_UNICODE_010_OrderByNfc" {
    // Simulate ORDER BY comparator behavior by normalizing precomposed vs decomposed forms
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const a = "\xC9"; // É precomposed
    const b = "E\xCC\x81"; // E + combining acute
    const na = try unicode.nfcNormalize(alloc, a);
    defer alloc.free(na);
    const nb = try unicode.nfcNormalize(alloc, b);
    defer alloc.free(nb);
    try std.testing.expect(std.mem.eql(u8, na, nb));
}
