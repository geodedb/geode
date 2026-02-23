const std = @import("std");

// CANARY: REQ=GQL-39075-RQ-0011; FEATURE="Unicode Confusable Detection"; ASPECT=ConfusableNeverSelf; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0011_ConfusableNeverSelf; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0012; FEATURE="Unicode Confusable Detection"; ASPECT=ConfusableIdentifierSqlstate42004; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0012_ConfusableDetectionSkeleton; OWNER=conformance; UPDATED=2026-02-23

/// A compact confusable mapping entry: Unicode codepoint -> skeleton string.
const ConfusableEntry = struct {
    codepoint: u21,
    skeleton: []const u8, // UTF-8 encoded skeleton (1-4 bytes typically)
};

/// Compact subset of UCD confusables.txt (Unicode TR#39).
/// Maps source codepoints to their skeleton equivalents.
/// Generated from the most commonly confused Latin/Cyrillic/Greek pairs.
const confusable_data = [_]ConfusableEntry{
    // Latin look-alikes for lowercase letters
    .{ .codepoint = 0x0430, .skeleton = "a" }, // Cyrillic a -> a
    .{ .codepoint = 0x0435, .skeleton = "e" }, // Cyrillic e -> e
    .{ .codepoint = 0x0456, .skeleton = "i" }, // Cyrillic i -> i
    .{ .codepoint = 0x043E, .skeleton = "o" }, // Cyrillic o -> o
    .{ .codepoint = 0x0440, .skeleton = "p" }, // Cyrillic p -> p
    .{ .codepoint = 0x0441, .skeleton = "c" }, // Cyrillic c -> c
    .{ .codepoint = 0x0445, .skeleton = "x" }, // Cyrillic x -> x
    .{ .codepoint = 0x0443, .skeleton = "y" }, // Cyrillic y -> y
    // Greek look-alikes
    .{ .codepoint = 0x03B1, .skeleton = "a" }, // Greek alpha -> a
    .{ .codepoint = 0x03B5, .skeleton = "e" }, // Greek epsilon -> e
    .{ .codepoint = 0x03BF, .skeleton = "o" }, // Greek omicron -> o
    .{ .codepoint = 0x03BD, .skeleton = "v" }, // Greek nu -> v
    .{ .codepoint = 0x03C1, .skeleton = "p" }, // Greek rho -> p
    .{ .codepoint = 0x03C7, .skeleton = "x" }, // Greek chi -> x
    // Latin extended look-alikes
    .{ .codepoint = 0x00E0, .skeleton = "a" }, // a-grave -> a
    .{ .codepoint = 0x00E1, .skeleton = "a" }, // a-acute -> a
    .{ .codepoint = 0x00E2, .skeleton = "a" }, // a-circumflex -> a
    .{ .codepoint = 0x00E3, .skeleton = "a" }, // a-tilde -> a
    .{ .codepoint = 0x00E4, .skeleton = "a" }, // a-umlaut -> a
    .{ .codepoint = 0x00E5, .skeleton = "a" }, // a-ring -> a
    .{ .codepoint = 0x00E8, .skeleton = "e" }, // e-grave -> e
    .{ .codepoint = 0x00E9, .skeleton = "e" }, // e-acute -> e
    .{ .codepoint = 0x00EA, .skeleton = "e" }, // e-circumflex -> e
    .{ .codepoint = 0x00EB, .skeleton = "e" }, // e-umlaut -> e
    .{ .codepoint = 0x00EC, .skeleton = "i" }, // i-grave -> i
    .{ .codepoint = 0x00ED, .skeleton = "i" }, // i-acute -> i
    .{ .codepoint = 0x00EE, .skeleton = "i" }, // i-circumflex -> i
    .{ .codepoint = 0x00EF, .skeleton = "i" }, // i-umlaut -> i
    .{ .codepoint = 0x00F2, .skeleton = "o" }, // o-grave -> o
    .{ .codepoint = 0x00F3, .skeleton = "o" }, // o-acute -> o
    .{ .codepoint = 0x00F4, .skeleton = "o" }, // o-circumflex -> o
    .{ .codepoint = 0x00F5, .skeleton = "o" }, // o-tilde -> o
    .{ .codepoint = 0x00F6, .skeleton = "o" }, // o-umlaut -> o
    .{ .codepoint = 0x00F9, .skeleton = "u" }, // u-grave -> u
    .{ .codepoint = 0x00FA, .skeleton = "u" }, // u-acute -> u
    .{ .codepoint = 0x00FB, .skeleton = "u" }, // u-circumflex -> u
    .{ .codepoint = 0x00FC, .skeleton = "u" }, // u-umlaut -> u
    .{ .codepoint = 0x00FD, .skeleton = "y" }, // y-acute -> y
    .{ .codepoint = 0x00FF, .skeleton = "y" }, // y-umlaut -> y
    .{ .codepoint = 0x00F1, .skeleton = "n" }, // n-tilde -> n
    .{ .codepoint = 0x00E7, .skeleton = "c" }, // c-cedilla -> c
    // Fullwidth Latin lowercase
    .{ .codepoint = 0xFF41, .skeleton = "a" }, // fullwidth a
    .{ .codepoint = 0xFF42, .skeleton = "b" }, // fullwidth b
    .{ .codepoint = 0xFF43, .skeleton = "c" }, // fullwidth c
    .{ .codepoint = 0xFF44, .skeleton = "d" }, // fullwidth d
    .{ .codepoint = 0xFF45, .skeleton = "e" }, // fullwidth e
    .{ .codepoint = 0xFF46, .skeleton = "f" }, // fullwidth f
    .{ .codepoint = 0xFF47, .skeleton = "g" }, // fullwidth g
    .{ .codepoint = 0xFF48, .skeleton = "h" }, // fullwidth h
    .{ .codepoint = 0xFF49, .skeleton = "i" }, // fullwidth i
    .{ .codepoint = 0xFF4A, .skeleton = "j" }, // fullwidth j
    .{ .codepoint = 0xFF4B, .skeleton = "k" }, // fullwidth k
    .{ .codepoint = 0xFF4C, .skeleton = "l" }, // fullwidth l
    .{ .codepoint = 0xFF4D, .skeleton = "m" }, // fullwidth m
    .{ .codepoint = 0xFF4E, .skeleton = "n" }, // fullwidth n
    .{ .codepoint = 0xFF4F, .skeleton = "o" }, // fullwidth o
    .{ .codepoint = 0xFF50, .skeleton = "p" }, // fullwidth p
    .{ .codepoint = 0xFF51, .skeleton = "q" }, // fullwidth q
    .{ .codepoint = 0xFF52, .skeleton = "r" }, // fullwidth r
    .{ .codepoint = 0xFF53, .skeleton = "s" }, // fullwidth s
    .{ .codepoint = 0xFF54, .skeleton = "t" }, // fullwidth t
    .{ .codepoint = 0xFF55, .skeleton = "u" }, // fullwidth u
    .{ .codepoint = 0xFF56, .skeleton = "v" }, // fullwidth v
    .{ .codepoint = 0xFF57, .skeleton = "w" }, // fullwidth w
    .{ .codepoint = 0xFF58, .skeleton = "x" }, // fullwidth x
    .{ .codepoint = 0xFF59, .skeleton = "y" }, // fullwidth y
    .{ .codepoint = 0xFF5A, .skeleton = "z" }, // fullwidth z
};

/// Look up the skeleton mapping for a single Unicode codepoint.
/// Returns the skeleton string if found, otherwise returns null
/// (meaning the character maps to itself).
fn lookupSkeleton(cp: u21) ?[]const u8 {
    for (confusable_data) |entry| {
        if (entry.codepoint == cp) return entry.skeleton;
    }
    return null;
}

/// Compute the confusable skeleton of a UTF-8 string.
/// The skeleton is formed by replacing each codepoint with its confusable
/// equivalent (from the TR#39 confusable data) and converting to lowercase.
///
/// Simplified implementation:
/// - Does not implement full NFD normalization (requires large Unicode tables)
/// - Does apply the confusable mapping and ASCII lowercasing
/// - Suitable for detecting most common confusable pairs
pub fn skeleton(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < input.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(input[i]) catch {
            // Invalid UTF-8: treat byte as-is (lowercased if ASCII)
            try result.append(std.ascii.toLower(input[i]));
            i += 1;
            continue;
        };
        if (i + seq_len > input.len) break;
        const cp = std.unicode.utf8Decode(input[i .. i + seq_len]) catch {
            try result.append(std.ascii.toLower(input[i]));
            i += 1;
            continue;
        };
        i += seq_len;

        if (lookupSkeleton(cp)) |skel| {
            // Map to skeleton characters
            try result.appendSlice(skel);
        } else if (cp < 128) {
            // ASCII: just lowercase
            try result.append(std.ascii.toLower(@intCast(cp)));
        } else {
            // Non-ASCII, not in confusables map: reproduce original bytes
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch seq_len;
            try result.appendSlice(buf[0..len]);
        }
    }

    return result.toOwnedSlice();
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
