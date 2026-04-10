const std = @import("std");

// CANARY: REQ=GQL-39075-RQ-0011; FEATURE="Unicode Confusable Detection"; ASPECT=ConfusableNeverSelf; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0011_ConfusableNeverSelf; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0012; FEATURE="Unicode Confusable Detection"; ASPECT=ConfusableIdentifierSqlstate42004; STATUS=IMPL; TEST=TestCANARY_GQL39075_RQ_0012_ConfusableDetectionSkeleton; OWNER=conformance; UPDATED=2026-02-23

/// A compact confusable mapping entry: Unicode codepoint -> skeleton string.
const ConfusableEntry = struct {
    codepoint: u21,
    skeleton: []const u8, // UTF-8 encoded skeleton (1-4 bytes typically)
};

/// Compact subset of UCD confusables.txt (Unicode TR#39).
/// Maps source codepoints to their skeleton equivalents.
/// MUST remain sorted by codepoint ascending (required for binary search in lookupSkeleton).
/// Covers: Latin extended upper+lower, Greek upper+lower, Cyrillic upper+lower, fullwidth Latin.
const confusable_data = [_]ConfusableEntry{
    // Latin extended uppercase (U+00C0–U+00DD)
    .{ .codepoint = 0x00C0, .skeleton = "a" }, // A-grave
    .{ .codepoint = 0x00C1, .skeleton = "a" }, // A-acute
    .{ .codepoint = 0x00C2, .skeleton = "a" }, // A-circumflex
    .{ .codepoint = 0x00C3, .skeleton = "a" }, // A-tilde
    .{ .codepoint = 0x00C4, .skeleton = "a" }, // A-umlaut
    .{ .codepoint = 0x00C5, .skeleton = "a" }, // A-ring
    .{ .codepoint = 0x00C7, .skeleton = "c" }, // C-cedilla
    .{ .codepoint = 0x00C8, .skeleton = "e" }, // E-grave
    .{ .codepoint = 0x00C9, .skeleton = "e" }, // E-acute
    .{ .codepoint = 0x00CA, .skeleton = "e" }, // E-circumflex
    .{ .codepoint = 0x00CB, .skeleton = "e" }, // E-umlaut
    .{ .codepoint = 0x00CC, .skeleton = "i" }, // I-grave
    .{ .codepoint = 0x00CD, .skeleton = "i" }, // I-acute
    .{ .codepoint = 0x00CE, .skeleton = "i" }, // I-circumflex
    .{ .codepoint = 0x00CF, .skeleton = "i" }, // I-umlaut
    .{ .codepoint = 0x00D1, .skeleton = "n" }, // N-tilde
    .{ .codepoint = 0x00D2, .skeleton = "o" }, // O-grave
    .{ .codepoint = 0x00D3, .skeleton = "o" }, // O-acute
    .{ .codepoint = 0x00D4, .skeleton = "o" }, // O-circumflex
    .{ .codepoint = 0x00D5, .skeleton = "o" }, // O-tilde
    .{ .codepoint = 0x00D6, .skeleton = "o" }, // O-umlaut
    .{ .codepoint = 0x00D9, .skeleton = "u" }, // U-grave
    .{ .codepoint = 0x00DA, .skeleton = "u" }, // U-acute
    .{ .codepoint = 0x00DB, .skeleton = "u" }, // U-circumflex
    .{ .codepoint = 0x00DC, .skeleton = "u" }, // U-umlaut
    .{ .codepoint = 0x00DD, .skeleton = "y" }, // Y-acute
    // Latin extended lowercase (U+00E0–U+00FF)
    .{ .codepoint = 0x00E0, .skeleton = "a" }, // a-grave
    .{ .codepoint = 0x00E1, .skeleton = "a" }, // a-acute
    .{ .codepoint = 0x00E2, .skeleton = "a" }, // a-circumflex
    .{ .codepoint = 0x00E3, .skeleton = "a" }, // a-tilde
    .{ .codepoint = 0x00E4, .skeleton = "a" }, // a-umlaut
    .{ .codepoint = 0x00E5, .skeleton = "a" }, // a-ring
    .{ .codepoint = 0x00E7, .skeleton = "c" }, // c-cedilla
    .{ .codepoint = 0x00E8, .skeleton = "e" }, // e-grave
    .{ .codepoint = 0x00E9, .skeleton = "e" }, // e-acute
    .{ .codepoint = 0x00EA, .skeleton = "e" }, // e-circumflex
    .{ .codepoint = 0x00EB, .skeleton = "e" }, // e-umlaut
    .{ .codepoint = 0x00EC, .skeleton = "i" }, // i-grave
    .{ .codepoint = 0x00ED, .skeleton = "i" }, // i-acute
    .{ .codepoint = 0x00EE, .skeleton = "i" }, // i-circumflex
    .{ .codepoint = 0x00EF, .skeleton = "i" }, // i-umlaut
    .{ .codepoint = 0x00F1, .skeleton = "n" }, // n-tilde
    .{ .codepoint = 0x00F2, .skeleton = "o" }, // o-grave
    .{ .codepoint = 0x00F3, .skeleton = "o" }, // o-acute
    .{ .codepoint = 0x00F4, .skeleton = "o" }, // o-circumflex
    .{ .codepoint = 0x00F5, .skeleton = "o" }, // o-tilde
    .{ .codepoint = 0x00F6, .skeleton = "o" }, // o-umlaut
    .{ .codepoint = 0x00F9, .skeleton = "u" }, // u-grave
    .{ .codepoint = 0x00FA, .skeleton = "u" }, // u-acute
    .{ .codepoint = 0x00FB, .skeleton = "u" }, // u-circumflex
    .{ .codepoint = 0x00FC, .skeleton = "u" }, // u-umlaut
    .{ .codepoint = 0x00FD, .skeleton = "y" }, // y-acute
    .{ .codepoint = 0x00FF, .skeleton = "y" }, // y-umlaut
    // Greek uppercase look-alikes (U+0391–U+03A7)
    .{ .codepoint = 0x0391, .skeleton = "a" }, // Greek capital Alpha
    .{ .codepoint = 0x0395, .skeleton = "e" }, // Greek capital Epsilon
    .{ .codepoint = 0x039D, .skeleton = "v" }, // Greek capital Nu (visually v)
    .{ .codepoint = 0x039F, .skeleton = "o" }, // Greek capital Omicron
    .{ .codepoint = 0x03A1, .skeleton = "p" }, // Greek capital Rho
    .{ .codepoint = 0x03A7, .skeleton = "x" }, // Greek capital Chi
    // Greek lowercase look-alikes (U+03B1–U+03C7)
    .{ .codepoint = 0x03B1, .skeleton = "a" }, // Greek alpha
    .{ .codepoint = 0x03B5, .skeleton = "e" }, // Greek epsilon
    .{ .codepoint = 0x03BD, .skeleton = "v" }, // Greek nu
    .{ .codepoint = 0x03BF, .skeleton = "o" }, // Greek omicron
    .{ .codepoint = 0x03C1, .skeleton = "p" }, // Greek rho
    .{ .codepoint = 0x03C7, .skeleton = "x" }, // Greek chi
    // Cyrillic uppercase look-alikes (U+0406, U+0410–U+0425)
    .{ .codepoint = 0x0406, .skeleton = "i" }, // Cyrillic capital І
    .{ .codepoint = 0x0410, .skeleton = "a" }, // Cyrillic capital А
    .{ .codepoint = 0x0415, .skeleton = "e" }, // Cyrillic capital Е
    .{ .codepoint = 0x041E, .skeleton = "o" }, // Cyrillic capital О
    .{ .codepoint = 0x0420, .skeleton = "p" }, // Cyrillic capital Р
    .{ .codepoint = 0x0421, .skeleton = "c" }, // Cyrillic capital С
    .{ .codepoint = 0x0423, .skeleton = "y" }, // Cyrillic capital У
    .{ .codepoint = 0x0425, .skeleton = "x" }, // Cyrillic capital Х
    // Cyrillic lowercase look-alikes (U+0430–U+0456)
    .{ .codepoint = 0x0430, .skeleton = "a" }, // Cyrillic а
    .{ .codepoint = 0x0435, .skeleton = "e" }, // Cyrillic е
    .{ .codepoint = 0x043E, .skeleton = "o" }, // Cyrillic о
    .{ .codepoint = 0x0440, .skeleton = "p" }, // Cyrillic р
    .{ .codepoint = 0x0441, .skeleton = "c" }, // Cyrillic с
    .{ .codepoint = 0x0443, .skeleton = "y" }, // Cyrillic у
    .{ .codepoint = 0x0445, .skeleton = "x" }, // Cyrillic х
    .{ .codepoint = 0x0456, .skeleton = "i" }, // Cyrillic і
    // Fullwidth Latin uppercase (U+FF21–U+FF3A)
    .{ .codepoint = 0xFF21, .skeleton = "a" }, // Ａ
    .{ .codepoint = 0xFF22, .skeleton = "b" }, // Ｂ
    .{ .codepoint = 0xFF23, .skeleton = "c" }, // Ｃ
    .{ .codepoint = 0xFF24, .skeleton = "d" }, // Ｄ
    .{ .codepoint = 0xFF25, .skeleton = "e" }, // Ｅ
    .{ .codepoint = 0xFF26, .skeleton = "f" }, // Ｆ
    .{ .codepoint = 0xFF27, .skeleton = "g" }, // Ｇ
    .{ .codepoint = 0xFF28, .skeleton = "h" }, // Ｈ
    .{ .codepoint = 0xFF29, .skeleton = "i" }, // Ｉ
    .{ .codepoint = 0xFF2A, .skeleton = "j" }, // Ｊ
    .{ .codepoint = 0xFF2B, .skeleton = "k" }, // Ｋ
    .{ .codepoint = 0xFF2C, .skeleton = "l" }, // Ｌ
    .{ .codepoint = 0xFF2D, .skeleton = "m" }, // Ｍ
    .{ .codepoint = 0xFF2E, .skeleton = "n" }, // Ｎ
    .{ .codepoint = 0xFF2F, .skeleton = "o" }, // Ｏ
    .{ .codepoint = 0xFF30, .skeleton = "p" }, // Ｐ
    .{ .codepoint = 0xFF31, .skeleton = "q" }, // Ｑ
    .{ .codepoint = 0xFF32, .skeleton = "r" }, // Ｒ
    .{ .codepoint = 0xFF33, .skeleton = "s" }, // Ｓ
    .{ .codepoint = 0xFF34, .skeleton = "t" }, // Ｔ
    .{ .codepoint = 0xFF35, .skeleton = "u" }, // Ｕ
    .{ .codepoint = 0xFF36, .skeleton = "v" }, // Ｖ
    .{ .codepoint = 0xFF37, .skeleton = "w" }, // Ｗ
    .{ .codepoint = 0xFF38, .skeleton = "x" }, // Ｘ
    .{ .codepoint = 0xFF39, .skeleton = "y" }, // Ｙ
    .{ .codepoint = 0xFF3A, .skeleton = "z" }, // Ｚ
    // Fullwidth Latin lowercase (U+FF41–U+FF5A)
    .{ .codepoint = 0xFF41, .skeleton = "a" }, // ａ
    .{ .codepoint = 0xFF42, .skeleton = "b" }, // ｂ
    .{ .codepoint = 0xFF43, .skeleton = "c" }, // ｃ
    .{ .codepoint = 0xFF44, .skeleton = "d" }, // ｄ
    .{ .codepoint = 0xFF45, .skeleton = "e" }, // ｅ
    .{ .codepoint = 0xFF46, .skeleton = "f" }, // ｆ
    .{ .codepoint = 0xFF47, .skeleton = "g" }, // ｇ
    .{ .codepoint = 0xFF48, .skeleton = "h" }, // ｈ
    .{ .codepoint = 0xFF49, .skeleton = "i" }, // ｉ
    .{ .codepoint = 0xFF4A, .skeleton = "j" }, // ｊ
    .{ .codepoint = 0xFF4B, .skeleton = "k" }, // ｋ
    .{ .codepoint = 0xFF4C, .skeleton = "l" }, // ｌ
    .{ .codepoint = 0xFF4D, .skeleton = "m" }, // ｍ
    .{ .codepoint = 0xFF4E, .skeleton = "n" }, // ｎ
    .{ .codepoint = 0xFF4F, .skeleton = "o" }, // ｏ
    .{ .codepoint = 0xFF50, .skeleton = "p" }, // ｐ
    .{ .codepoint = 0xFF51, .skeleton = "q" }, // ｑ
    .{ .codepoint = 0xFF52, .skeleton = "r" }, // ｒ
    .{ .codepoint = 0xFF53, .skeleton = "s" }, // ｓ
    .{ .codepoint = 0xFF54, .skeleton = "t" }, // ｔ
    .{ .codepoint = 0xFF55, .skeleton = "u" }, // ｕ
    .{ .codepoint = 0xFF56, .skeleton = "v" }, // ｖ
    .{ .codepoint = 0xFF57, .skeleton = "w" }, // ｗ
    .{ .codepoint = 0xFF58, .skeleton = "x" }, // ｘ
    .{ .codepoint = 0xFF59, .skeleton = "y" }, // ｙ
    .{ .codepoint = 0xFF5A, .skeleton = "z" }, // ｚ
};

/// Look up the skeleton mapping for a single Unicode codepoint.
/// Returns the skeleton string if found, otherwise returns null
/// (meaning the character maps to itself in the skeleton).
/// Uses binary search — confusable_data MUST be sorted by codepoint ascending.
fn lookupSkeleton(cp: u21) ?[]const u8 {
    var lo: usize = 0;
    var hi: usize = confusable_data.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry = confusable_data[mid];
        if (entry.codepoint < cp) {
            lo = mid + 1;
        } else if (entry.codepoint > cp) {
            hi = mid;
        } else {
            return entry.skeleton;
        }
    }
    return null;
}

/// Compute the confusable skeleton of a UTF-8 string.
/// The skeleton is formed by replacing each codepoint with its confusable
/// equivalent (from the TR#39 confusable data table) and lowercasing.
///
/// Simplified implementation notes:
/// - Full NFD normalization is not applied (requires large Unicode tables)
/// - ASCII codepoints (< 128) are lowercased via std.ascii.toLower
/// - Non-ASCII codepoints: case folding is applied via the confusable_data
///   table (which includes both upper and lowercase variants for Latin extended,
///   Greek, and Cyrillic). Unmapped non-ASCII codepoints are reproduced as-is
///   (no case folding for those characters).
/// - Suitable for detecting the most common confusable identifier pairs
pub fn skeleton(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(input[i]) catch {
            // Invalid UTF-8: treat byte as-is (lowercased if ASCII)
            try result.append(allocator, std.ascii.toLower(input[i]));
            i += 1;
            continue;
        };
        if (i + seq_len > input.len) break;
        const cp = std.unicode.utf8Decode(input[i .. i + seq_len]) catch {
            try result.append(allocator, std.ascii.toLower(input[i]));
            i += 1;
            continue;
        };
        i += seq_len;

        if (lookupSkeleton(cp)) |skel| {
            // Map to skeleton characters
            try result.appendSlice(allocator, skel);
        } else if (cp < 128) {
            // ASCII: just lowercase
            try result.append(allocator, std.ascii.toLower(@intCast(cp)));
        } else {
            // Non-ASCII, not in confusables map: reproduce original bytes
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch seq_len;
            try result.appendSlice(allocator, buf[0..len]);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Returns true if two identifiers are confusable (their skeletons are equal)
/// but are NOT identical strings.
///
/// Per ISO 39075 RQ-0011: confusable(s, s) MUST return false.
/// Per ISO 39075 RQ-0012: confusable pairs should raise SQLSTATE 42004.
pub fn confusable(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    // RQ-0011: a string is never confusable with itself
    if (std.mem.eql(u8, a, b)) return false;

    const skel_a = try skeleton(allocator, a);
    defer allocator.free(skel_a);
    const skel_b = try skeleton(allocator, b);
    defer allocator.free(skel_b);

    return std.mem.eql(u8, skel_a, skel_b);
}

// ============================================================================
// TESTS
// ============================================================================

test "TestCANARY_GQL39075_RQ_0011_ConfusableNeverSelf" {
    // RQ-0011: a confusable is never confusable with itself
    const alloc = std.testing.allocator;
    try std.testing.expect(!try confusable(alloc, "hello", "hello"));
    try std.testing.expect(!try confusable(alloc, "myVar", "myVar"));
    try std.testing.expect(!try confusable(alloc, "", ""));
    // Unicode identifier -- must not be confusable with itself
    try std.testing.expect(!try confusable(alloc, "\xD0\xB0bc", "\xD0\xB0bc")); // Cyrillic a
}

test "TestCANARY_GQL39075_RQ_0012_ConfusableDetectionSkeleton" {
    // RQ-0012: Confusable identifiers should be detected
    const alloc = std.testing.allocator;
    // "abc" vs "abc" with Cyrillic a (U+0430 looks like Latin a)
    const latin_a = "abc";
    const cyrillic_a = "\xD0\xB0bc"; // Cyrillic a followed by bc
    try std.testing.expect(try confusable(alloc, latin_a, cyrillic_a));
    // Distinct identifiers that are NOT confusable
    try std.testing.expect(!try confusable(alloc, "hello", "world"));
    // Same skeleton via fullwidth
    const fullwidth_abc = "\xEF\xBD\x81\xEF\xBD\x82\xEF\xBD\x83"; // fullwidth abc
    try std.testing.expect(try confusable(alloc, "abc", fullwidth_abc));
}

test "skeleton_ascii_lowercase" {
    const alloc = std.testing.allocator;
    const s = try skeleton(alloc, "Hello");
    defer alloc.free(s);
    try std.testing.expectEqualStrings("hello", s);
}

test "skeleton_cyrillic_maps_to_latin" {
    const alloc = std.testing.allocator;
    // Cyrillic a (U+0430) should map to "a"
    const s = try skeleton(alloc, "\xD0\xB0");
    defer alloc.free(s);
    try std.testing.expectEqualStrings("a", s);
}
