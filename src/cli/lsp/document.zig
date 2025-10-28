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
