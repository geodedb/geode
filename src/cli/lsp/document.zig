// Module implementation
// Document state management for LSP server

const std = @import("std");
const Allocator = std.mem.Allocator;

/// GAP-0817: LSP position encoding (LSP 3.17 `PositionEncodingKind`). An LSP
/// `Position.character` is an offset into a line measured in CODE UNITS of the
/// negotiated encoding. The protocol DEFAULT (when the client offers nothing)
/// is UTF-16 — so a line containing multi-byte characters (e.g. `é`, an emoji)
/// places later tokens at a `character` value that differs from the byte
/// offset. Geode's document internals are UTF-8 byte slices, so every incoming
/// `character` must be translated from the negotiated encoding's code units to
/// a UTF-8 byte column before it can index the text. Failing to do this is the
/// exact UTF-8/UTF-16 drift this gap closes.
pub const PositionEncoding = enum {
    utf8,
    utf16,
    utf32,

    /// The LSP wire string for this encoding (the value advertised in the
    /// `initialize` result's `capabilities.positionEncoding`).
    pub fn toWire(self: PositionEncoding) []const u8 {
        return switch (self) {
            .utf8 => "utf-8",
            .utf16 => "utf-16",
            .utf32 => "utf-32",
        };
    }

    /// Parse an LSP `PositionEncodingKind` wire string. Returns null for an
    /// unknown value so the negotiator can skip it.
    pub fn fromWire(s: []const u8) ?PositionEncoding {
        if (std.mem.eql(u8, s, "utf-8")) return .utf8;
        if (std.mem.eql(u8, s, "utf-16")) return .utf16;
        if (std.mem.eql(u8, s, "utf-32")) return .utf32;
        return null;
    }
};

/// GAP-0817: number of code units a single Unicode code point occupies in
/// `encoding`. `byte_len` is the code point's UTF-8 byte length (1–4).
///   - utf-8:  the byte length itself.
///   - utf-16: 1 for code points in the BMP (UTF-8 length 1–3), 2 for
///             supplementary code points (UTF-8 length 4 — a surrogate pair).
///   - utf-32: always 1 (one code unit == one code point).
fn codeUnitsForCodePoint(byte_len: u3, encoding: PositionEncoding) u32 {
    return switch (encoding) {
        .utf8 => byte_len,
        .utf16 => if (byte_len == 4) 2 else 1,
        .utf32 => 1,
    };
}

/// GAP-0817: translate a `character` offset expressed in `encoding`'s code
/// units into a UTF-8 BYTE column within `line_text`. Fail-safe on malformed
/// UTF-8: an invalid lead byte is treated as a single-byte code unit so the
/// walk always terminates and never panics (a degraded-but-bounded result is
/// preferable to a crash on hostile input). If `character` lands past the end
/// of the line, the line's full byte length is returned (clamped), matching
/// the lenient `getOffset` boundary behavior. The returned value is a byte
/// column suitable for the byte-based `getOffset`.
pub fn codeUnitsToByteColumn(line_text: []const u8, character: u32, encoding: PositionEncoding) u32 {
    if (character == 0) return 0;
    // UTF-8 fast path: code units ARE bytes, but we still clamp to the line
    // length and validate continuation so a multi-byte char isn't split.
    var byte_i: usize = 0;
    var units: u32 = 0;
    while (byte_i < line_text.len) {
        if (units >= character) break;
        const lead = line_text[byte_i];
        const seq_len: u3 = std.unicode.utf8ByteSequenceLength(lead) catch 1;
        // Guard against a truncated/invalid sequence at the tail.
        const safe_len: usize = blk: {
            if (seq_len == 1) break :blk 1;
            if (byte_i + seq_len > line_text.len) break :blk 1;
            break :blk seq_len;
        };
        units += codeUnitsForCodePoint(@intCast(safe_len), encoding);
        byte_i += safe_len;
    }
    return @intCast(byte_i);
}

/// GAP-0817 (outbound): the inverse of `codeUnitsToByteColumn`. Translate a
/// UTF-8 BYTE column within `line_text` into a `character` offset expressed in
/// `encoding`'s code units, suitable for placing into an outbound LSP
/// `Position.character`. Geode's feature providers compute byte columns
/// (`offset - line_start`); a utf-16/utf-32 client expects code-unit columns, so
/// every outbound position on a multi-byte line must be converted or the client
/// renders ranges/locations at the wrong column.
///
/// Fail-safe, mirroring `codeUnitsToByteColumn`: an invalid lead byte is treated
/// as a single-byte sequence so the walk always terminates; a `byte_col` past
/// the end of the line clamps to the line's total code-unit width. UTF-8
/// sessions are an identity passthrough (code units ARE bytes) but still clamp.
pub fn byteColumnToCodeUnits(line_text: []const u8, byte_col: u32, encoding: PositionEncoding) u32 {
    if (byte_col == 0) return 0;
    var byte_i: usize = 0;
    var units: u32 = 0;
    while (byte_i < line_text.len) {
        if (byte_i >= byte_col) break;
        const lead = line_text[byte_i];
        const seq_len: u3 = std.unicode.utf8ByteSequenceLength(lead) catch 1;
        const safe_len: usize = blk: {
            if (seq_len == 1) break :blk 1;
            if (byte_i + seq_len > line_text.len) break :blk 1;
            break :blk seq_len;
        };
        // If byte_col lands in the MIDDLE of a multi-byte sequence (malformed
        // input from a client), count the whole code point — a code-unit column
        // cannot point inside a code point. The walk still terminates because
        // byte_i advances past byte_col.
        units += codeUnitsForCodePoint(@intCast(safe_len), encoding);
        byte_i += safe_len;
    }
    return units;
}

pub const Document = struct {
    uri: []const u8,
    text: []const u8,
    version: i32,
    allocator: Allocator,

    pub fn init(allocator: Allocator, uri: []const u8, text: []const u8, version: i32) !*Document {
        const doc = try allocator.create(Document);
        doc.* = .{
            .uri = try allocator.dupe(u8, uri),
            .text = try allocator.dupe(u8, text),
            .version = version,
            .allocator = allocator,
        };
        return doc;
    }

    pub fn deinit(self: *Document) void {
        self.allocator.free(self.uri);
        self.allocator.free(self.text);
        self.allocator.destroy(self);
    }

    pub fn update(self: *Document, new_text: []const u8, new_version: i32) !void {
        self.allocator.free(self.text);
        self.text = try self.allocator.dupe(u8, new_text);
        self.version = new_version;
    }

    pub fn getLineContent(self: *const Document, line: u32) ?[]const u8 {
        var current_line: u32 = 0;
        var line_start: usize = 0;

        for (self.text, 0..) |c, i| {
            if (current_line == line) {
                if (c == '\n') {
                    return self.text[line_start..i];
                }
            } else if (c == '\n') {
                current_line += 1;
                line_start = i + 1;
            }
        }

        if (current_line == line) {
            return self.text[line_start..];
        }

        return null;
    }

    pub fn getOffset(self: *const Document, line: u32, character: u32) ?usize {
        var current_line: u32 = 0;
        var line_start: usize = 0;

        for (self.text, 0..) |c, i| {
            if (c == '\n') {
                if (current_line == line) {
                    const line_length = i - line_start;
                    if (character <= line_length) {
                        return line_start + character;
                    }
                    return null;
                }
                current_line += 1;
                line_start = i + 1;
            }
        }

        if (current_line == line) {
            const line_length = self.text.len - line_start;
            if (character <= line_length) {
                return line_start + character;
            }
        }

        return null;
    }

    pub fn getWordAt(self: *const Document, offset: usize) ?[]const u8 {
        if (offset >= self.text.len) return null;

        var start = offset;
        var end = offset;

        // Move start back to beginning of word
        while (start > 0 and isIdentifierChar(self.text[start - 1])) {
            start -= 1;
        }

        // Move end forward to end of word
        while (end < self.text.len and isIdentifierChar(self.text[end])) {
            end += 1;
        }

        if (start == end) return null;
        return self.text[start..end];
    }

    fn isIdentifierChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    /// Find the position (line, column) of an identifier in the document text.
    /// Searches case-insensitively and ensures the match is a whole word.
    /// Skips comments (-- and // single-line, /* */ multi-line) and string literals.
    /// Returns null if not found.
    pub fn findIdentifierPosition(self: *const Document, identifier: []const u8) ?struct { line: u32, character: u32 } {
        if (identifier.len == 0) return null;

        var line: u32 = 0;
        var line_start: usize = 0;
        var i: usize = 0;
        var in_multiline_comment = false;

        while (i < self.text.len) {
            // Check for newline
            if (self.text[i] == '\n') {
                line += 1;
                line_start = i + 1;
                i += 1;
                continue;
            }

            // Skip multi-line comments /* ... */
            if (in_multiline_comment) {
                if (i + 1 < self.text.len and self.text[i] == '*' and self.text[i + 1] == '/') {
                    in_multiline_comment = false;
                    i += 2;
                } else {
                    i += 1;
                }
                continue;
            }

            // Check for start of multi-line comment
            if (i + 1 < self.text.len and self.text[i] == '/' and self.text[i + 1] == '*') {
                in_multiline_comment = true;
                i += 2;
                continue;
            }

            // Check for single-line comments: -- or //
            if (i + 1 < self.text.len) {
                const c0 = self.text[i];
                const c1 = self.text[i + 1];
                if ((c0 == '-' and c1 == '-') or (c0 == '/' and c1 == '/')) {
                    // Skip to end of line
                    while (i < self.text.len and self.text[i] != '\n') {
                        i += 1;
                    }
                    continue;
                }
            }

            // Skip string literals (single and double quoted)
            if (self.text[i] == '\'' or self.text[i] == '"') {
                const quote_char = self.text[i];
                i += 1;
                // Skip until closing quote (handle escape sequences)
                while (i < self.text.len) {
                    if (self.text[i] == '\n') {
                        // Count newlines inside strings for accurate line tracking
                        line += 1;
                        line_start = i + 1;
                        i += 1;
                    } else if (self.text[i] == '\\' and i + 1 < self.text.len) {
                        // Skip escaped character
                        i += 2;
                    } else if (self.text[i] == quote_char) {
                        i += 1;
                        break;
                    } else {
                        i += 1;
                    }
                }
                continue;
            }

            // Check if this could be the start of the identifier
            // Must be preceded by non-identifier character or be at start
            const at_word_boundary = i == 0 or !isIdentifierChar(self.text[i - 1]);
            if (!at_word_boundary) {
                i += 1;
                continue;
            }

            // Check if we have enough characters left
            if (i + identifier.len > self.text.len) {
                i += 1;
                continue;
            }

            // Case-insensitive comparison
            var match = true;
            for (identifier, 0..) |c, j| {
                const doc_char = self.text[i + j];
                if (std.ascii.toLower(c) != std.ascii.toLower(doc_char)) {
                    match = false;
                    break;
                }
            }

            if (match) {
                // Check that it's followed by non-identifier character or end
                const end_pos = i + identifier.len;
                const at_word_end = end_pos >= self.text.len or !isIdentifierChar(self.text[end_pos]);

                if (at_word_end) {
                    return .{
                        .line = line,
                        .character = @intCast(i - line_start),
                    };
                }
            }

            i += 1;
        }

        return null;
    }
};

pub const DocumentStore = struct {
    documents: std.StringHashMap(*Document),
    allocator: Allocator,

    pub fn init(allocator: Allocator) DocumentStore {
        return .{
            .documents = std.StringHashMap(*Document).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DocumentStore) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.documents.deinit();
    }

    pub fn open(self: *DocumentStore, uri: []const u8, text: []const u8, version: i32) !void {
        // If document already exists, close it first to prevent leaks
        if (self.documents.get(uri)) |existing_doc| {
            _ = self.documents.remove(uri);
            existing_doc.deinit();
        }

        const doc = try Document.init(self.allocator, uri, text, version);
        try self.documents.put(doc.uri, doc);
    }

    pub fn close(self: *DocumentStore, uri: []const u8) void {
        if (self.documents.get(uri)) |doc| {
            _ = self.documents.remove(uri);
            doc.deinit();
        }
    }

    pub fn get(self: *const DocumentStore, uri: []const u8) ?*Document {
        return self.documents.get(uri);
    }

    pub fn update(self: *DocumentStore, uri: []const u8, text: []const u8, version: i32) !void {
        if (self.documents.get(uri)) |doc| {
            try doc.update(text, version);
        }
    }
};
