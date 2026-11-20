// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 CodePros
// CANARY: REQ=REQ-REPL-UTF8-EDIT-6487; FEATURE="REPL UTF-8 line editing"; ASPECT=GraphemeCursor; STATUS=TESTED; TEST=tests/test_sonny6487_repl_utf8.zig; OWNER=cli; UPDATED=2026-11-13

//! SONNY-6487: UTF-8-aware helpers for the interactive line editor
//! (repl_loop.zig, keymap_emacs.zig, keymap_vi.zig). The editor moved,
//! deleted and measured the line one BYTE at a time, so a typed `é` was
//! dropped by the keymaps, and a pasted one could be split by Backspace or
//! a cursor move, leaving invalid UTF-8 in the statement.
//!
//! Cursor moves and single-character deletes step over a whole grapheme
//! cluster (UAX #29, the `strings` library's segmentation), so `e` + U+0301
//! is one step. Display width: a nonspacing or enclosing mark (Mn, Me) or a
//! format character (Cf) takes no column, every other code point one.
//! Known gap: East Asian wide characters (CJK, most emoji) take two terminal
//! columns, but neither this repository nor its dependencies carry the East
//! Asian Width table, so they are counted as one and the cursor is drawn one
//! column left of its place after each such character. The text itself is
//! never corrupted.

const std = @import("std");
const strings = @import("strings");

/// Start of the grapheme cluster that ends at `cursor` (`cursor` is on a
/// boundary). A newline is its own cluster.
pub fn prevBoundary(text: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..cursor], '\n')) |nl| nl + 1 else 0;
    if (line_start == cursor) return cursor - 1;
    var it = strings.grapheme.iterator(text[line_start..cursor]);
    var last: usize = 0;
    var off: usize = 0;
    while (it.next()) |g| {
        last = off;
        off += g.len;
    }
    return line_start + last;
}

/// End of the grapheme cluster that starts at `cursor`.
pub fn nextBoundary(text: []const u8, cursor: usize) usize {
    if (cursor >= text.len) return text.len;
    if (text[cursor] == '\n') return cursor + 1;
    const line_end = std.mem.indexOfScalarPos(u8, text, cursor, '\n') orelse text.len;
    var it = strings.grapheme.iterator(text[cursor..line_end]);
    const g = it.next() orelse return cursor + 1;
    return cursor + g.len;
}

/// Remove `list.items[start..end]` (byte offsets on boundaries).
pub fn removeRange(list: *std.ArrayList(u8), start: usize, end: usize) void {
    std.mem.copyForwards(u8, list.items[start..], list.items[end..]);
    list.items.len -= end - start;
}

pub const Glyph = struct {
    /// Bytes of the code point at the index (1 for an invalid or
    /// truncated sequence, which is shown as one replacement column).
    len: usize,
    /// Terminal columns it takes.
    width: usize,
};

/// The code point starting at `i` (not a newline or tab: the callers expand
/// those themselves).
pub fn glyphAt(text: []const u8, i: usize) Glyph {
    const b = text[i];
    if (b < 0x80) return .{ .len = 1, .width = 1 };
    const len = std.unicode.utf8ByteSequenceLength(b) catch return .{ .len = 1, .width = 1 };
    if (i + len > text.len) return .{ .len = 1, .width = 1 };
    const cp = std.unicode.utf8Decode(text[i..][0..len]) catch return .{ .len = 1, .width = 1 };
    return .{ .len = len, .width = switch (strings.categories.getCategory(cp)) {
        .Mn, .Me, .Cf => 0,
        else => 1,
    } };
}

/// Columns `text` takes (no newlines or tabs).
pub fn displayWidth(text: []const u8) usize {
    var i: usize = 0;
    var w: usize = 0;
    while (i < text.len) {
        const g = glyphAt(text, i);
        w += g.width;
        i += g.len;
    }
    return w;
}

test "SONNY-6487: boundaries step over multi-byte code points and combining marks" {
    const s = "a\u{e9}e\u{301}\u{20ac}b"; // a, é (2 bytes), e + U+0301, €, b
    try std.testing.expectEqual(@as(usize, 1), nextBoundary(s, 0));
    try std.testing.expectEqual(@as(usize, 3), nextBoundary(s, 1));
    try std.testing.expectEqual(@as(usize, 6), nextBoundary(s, 3));
    try std.testing.expectEqual(@as(usize, 9), nextBoundary(s, 6));
    try std.testing.expectEqual(@as(usize, 10), nextBoundary(s, 9));
    try std.testing.expectEqual(@as(usize, 9), prevBoundary(s, 10));
    try std.testing.expectEqual(@as(usize, 6), prevBoundary(s, 9));
    try std.testing.expectEqual(@as(usize, 3), prevBoundary(s, 6));
    try std.testing.expectEqual(@as(usize, 1), prevBoundary(s, 3));
    try std.testing.expectEqual(@as(usize, 0), prevBoundary(s, 1));
    try std.testing.expectEqual(@as(usize, 5), displayWidth(s));
}

test "SONNY-6487: removeRange deletes one whole cluster" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.appendSlice(std.testing.allocator, "xe\u{301}y");
    removeRange(&list, 1, nextBoundary(list.items, 1));
    try std.testing.expectEqualStrings("xy", list.items);
}

test "SONNY-6487: a newline is its own cluster and an invalid byte is one column" {
    const s = "\u{e9}\n\u{e9}";
    try std.testing.expectEqual(@as(usize, 2), prevBoundary(s, 3));
    try std.testing.expectEqual(@as(usize, 0), prevBoundary(s, 2));
    try std.testing.expectEqual(@as(usize, 3), nextBoundary(s, 2));
    const bad = [_]u8{ 'a', 0xc3 }; // truncated sequence while typing
    try std.testing.expectEqual(@as(usize, 2), displayWidth(&bad));
    try std.testing.expectEqual(@as(usize, 1), prevBoundary(&bad, 2));
}
