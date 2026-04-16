const std = @import("std");
const geode = @import("geode");
const unicode = geode.unicode;

// TestCANARY_REQ_GQL_UNICODE_012_Utf8ToUtf16RoundTrip
// TestCANARY_REQ_GQL_UNICODE_013_Utf16ToUtf8RoundTrip
// TestCANARY_REQ_GQL_UNICODE_014_Wtf8Lossy
// Covers REQ-GQL-UNICODE-012/013/014 promoting to TESTED when passing.

pub fn main() !void {}

test "TestCANARY_REQ_GQL_UNICODE_012_Utf8ToUtf16RoundTrip" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const samples = [_][]const u8{ "", "hello", "Grüße", "𝄞mus𝄢ic", "Straße" };
    for (samples) |s| {
        const units = try unicode.utf8ToUtf16Alloc(alloc, s);
        defer alloc.free(units);
        const back = try unicode.utf16ToUtf8Alloc(alloc, units);
        defer alloc.free(back);
        try std.testing.expectEqualStrings(s, back);
    }
}

test "TestCANARY_REQ_GQL_UNICODE_013_Utf16ToUtf8RoundTrip" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    // Single explicit surrogate pair U+1F600 GRINNING FACE 😀 (0xD83D 0xDE00)
    const utf16 = [_]u16{ 0xD83D, 0xDE00 };
    const utf8 = try unicode.utf16ToUtf8Alloc(alloc, &utf16);
    defer alloc.free(utf8);
    try std.testing.expect(std.mem.eql(u8, utf8, "😀"));
    const round_units = try unicode.utf8ToUtf16Alloc(alloc, utf8);
    defer alloc.free(round_units);
    try std.testing.expect(round_units.len == 2 and round_units[0] == 0xD83D and round_units[1] == 0xDE00);
}

test "TestCANARY_REQ_GQL_UNICODE_014_Wtf8Lossy" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    // Ill-formed WTF-8: Lone surrogate 0xD800 sequence encoded in WTF-8 as 0xED 0xA0 0x80
    const wtf8 = [_]u8{ 0xED, 0xA0, 0x80 };
    const lossy = try unicode.wtf8LossyToUtf8Alloc(alloc, &wtf8);
    defer alloc.free(lossy);
    // Expect replacement char U+FFFD 0xEF 0xBF 0xBD
    try std.testing.expect(lossy.len == 3);
    try std.testing.expect(lossy[0] == 0xEF and lossy[1] == 0xBF and lossy[2] == 0xBD);
}
