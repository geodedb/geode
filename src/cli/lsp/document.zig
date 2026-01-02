// CANARY: LSP_DOCUMENT_MANAGEMENT
// Document state management for LSP server

const std = @import("std");
const Allocator = std.mem.Allocator;

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
