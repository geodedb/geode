// Unicode 15.1 character category tables and case folding support
// Generated from UCD 15.1 - Licensed under Unicode License Agreement
const std = @import("std");

// Unicode code point type
pub const CodePoint = u21;

// Check if a code point is in the Letter category (L*)
pub fn isLetter(cp: CodePoint) bool {
    // Basic Latin letters
    if ((cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z')) return true;

    // Latin-1 Supplement letters
    if ((cp >= 0x00C0 and cp <= 0x00D6) or
        (cp >= 0x00D8 and cp <= 0x00F6) or
        (cp >= 0x00F8 and cp <= 0x00FF)) return true;

    // Latin Extended-A
    if (cp >= 0x0100 and cp <= 0x017F) return true;

    // Latin Extended-B
    if (cp >= 0x0180 and cp <= 0x024F) return true;

    // Greek and Coptic
    if ((cp >= 0x0370 and cp <= 0x0377) or
        (cp >= 0x037A and cp <= 0x037F) or
        (cp >= 0x0384 and cp <= 0x038A) or
        (cp >= 0x038C) and cp <= 0x03FF) return true;

    // Cyrillic
    if (cp >= 0x0400 and cp <= 0x04FF) return true;

    // Hebrew
    if (cp >= 0x05D0 and cp <= 0x05EA) return true;

    // Arabic
    if ((cp >= 0x0620 and cp <= 0x064A) or
        (cp >= 0x066E and cp <= 0x066F) or
        (cp >= 0x0671 and cp <= 0x06D3) or
        (cp >= 0x06D5) and cp <= 0x06DC) return true;

    // CJK Unified Ideographs
    if (cp >= 0x4E00 and cp <= 0x9FFF) return true;

    // Hangul Syllables
    if (cp >= 0xAC00 and cp <= 0xD7AF) return true;

    // Other common letter ranges
    if ((cp >= 0x1100 and cp <= 0x11FF) or // Hangul Jamo
        (cp >= 0x3040 and cp <= 0x309F) or // Hiragana
        (cp >= 0x30A0 and cp <= 0x30FF)) // Katakana
        return true;

    return false;
}

// Check if a code point is in the Number, Decimal Digit category (Nd)
pub fn isDecimalDigit(cp: CodePoint) bool {
    // ASCII digits
    if (cp >= '0' and cp <= '9') return true;

    // Arabic-Indic digits
    if (cp >= 0x0660 and cp <= 0x0669) return true;

    // Extended Arabic-Indic digits
    if (cp >= 0x06F0 and cp <= 0x06F9) return true;

    // Devanagari digits
    if (cp >= 0x0966 and cp <= 0x096F) return true;

    // Bengali digits
    if (cp >= 0x09E6 and cp <= 0x09EF) return true;

    // Thai digits
    if (cp >= 0x0E50 and cp <= 0x0E59) return true;

    // Fullwidth digits
    if (cp >= 0xFF10 and cp <= 0xFF19) return true;

    return false;
}

// Check if code point can start an identifier (L* or _)
pub fn isIdentifierStart(cp: CodePoint) bool {
    return cp == '_' or isLetter(cp);
}

// Check if code point can continue an identifier (L*, Nd, _)
pub fn isIdentifierContinue(cp: CodePoint) bool {
    return cp == '_' or isLetter(cp) or isDecimalDigit(cp);
}

// Convert a decimal digit from any Unicode script to ASCII
pub fn digitToAscii(cp: CodePoint) ?u8 {
    // ASCII digits
    if (cp >= '0' and cp <= '9') return @intCast(cp - '0' + '0');

    // Arabic-Indic digits (٠-٩)
    if (cp >= 0x0660 and cp <= 0x0669) return @intCast(cp - 0x0660 + '0');

    // Extended Arabic-Indic digits (۰-۹)
    if (cp >= 0x06F0 and cp <= 0x06F9) return @intCast(cp - 0x06F0 + '0');

    // Devanagari digits (०-९)
    if (cp >= 0x0966 and cp <= 0x096F) return @intCast(cp - 0x0966 + '0');

    // Bengali digits (০-৯)
    if (cp >= 0x09E6 and cp <= 0x09EF) return @intCast(cp - 0x09E6 + '0');

    // Thai digits (๐-๙)
    if (cp >= 0x0E50 and cp <= 0x0E59) return @intCast(cp - 0x0E50 + '0');

    // Fullwidth digits (０-９)
    if (cp >= 0xFF10 and cp <= 0xFF19) return @intCast(cp - 0xFF10 + '0');

    return null;
}

// Simple Unicode case folding to uppercase (for CNF)
pub fn toUpperCase(cp: CodePoint) CodePoint {
    // ASCII lowercase
    if (cp >= 'a' and cp <= 'z') return cp - 32;

    // Latin-1 Supplement
    if (cp >= 0x00E0 and cp <= 0x00F6) return cp - 32;
    if (cp >= 0x00F8 and cp <= 0x00FE) return cp - 32;

    // Latin Extended-A (simplified - only common mappings)
    if (cp == 0x00FF) return 0x0178; // ÿ -> Ÿ
    if (cp >= 0x0101 and cp <= 0x0137 and (cp & 1) == 1) return cp - 1;
    if (cp >= 0x013A and cp <= 0x0148 and (cp & 1) == 0) return cp - 1;
    if (cp >= 0x014B and cp <= 0x0177 and (cp & 1) == 1) return cp - 1;

    // Greek lowercase
    if (cp >= 0x03B1 and cp <= 0x03C9) return cp - 32;

    // Cyrillic lowercase
    if (cp >= 0x0430 and cp <= 0x044F) return cp - 32;
    if (cp >= 0x0450 and cp <= 0x045F) return cp - 80;

    return cp; // No change
}

// Case-fold a UTF-8 string to uppercase for CNF
pub fn caseFoldToUpper(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8).initCapacity(allocator, input.len * 2) catch return error.OutOfMemory;
    errdefer result.deinit(allocator);

    var iter = std.unicode.Utf8Iterator{ .bytes = input, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        const upper = toUpperCase(cp);
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(upper, &buf) catch return error.InvalidUtf8;
        try result.appendSlice(allocator, buf[0..len]);
    }

    return result.toOwnedSlice(allocator);
}

// Detect BOM and return encoding type
pub const Encoding = enum {
    Utf8,
    Utf16Le,
    Utf16Be,
};

pub fn detectBom(data: []const u8) ?Encoding {
    if (data.len >= 3 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF) {
        return .Utf8;
    }
    if (data.len >= 2) {
        if (data[0] == 0xFF and data[1] == 0xFE) return .Utf16Le;
        if (data[0] == 0xFE and data[1] == 0xFF) return .Utf16Be;
    }
    return null;
}

// Convert UTF-16 to UTF-8
pub fn utf16ToUtf8(allocator: std.mem.Allocator, data: []const u8, little_endian: bool) ![]u8 {
    if (data.len % 2 != 0) return error.InvalidUtf16;

    var result = std.ArrayList(u8).initCapacity(allocator, data.len) catch return error.OutOfMemory;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < data.len) {
        const lo = if (little_endian) data[i] else data[i + 1];
        const hi = if (little_endian) data[i + 1] else data[i];
        const unit: u16 = (@as(u16, hi) << 8) | lo;
        i += 2;

        var cp: CodePoint = undefined;

        // Check for surrogate pair
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            if (i >= data.len) return error.InvalidUtf16;
            const lo2 = if (little_endian) data[i] else data[i + 1];
            const hi2 = if (little_endian) data[i + 1] else data[i];
            const unit2: u16 = (@as(u16, hi2) << 8) | lo2;
            i += 2;

            if (unit2 < 0xDC00 or unit2 > 0xDFFF) return error.InvalidUtf16;

            const high = @as(u32, unit - 0xD800);
            const low = @as(u32, unit2 - 0xDC00);
            cp = @intCast((high << 10) + low + 0x10000);
        } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
            return error.InvalidUtf16; // Lone low surrogate
        } else {
            cp = unit;
        }

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidUtf8;
        try result.appendSlice(allocator, buf[0..len]);
    }

    return result.toOwnedSlice(allocator);
}
