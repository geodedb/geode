// Find-references provider for the GQL/Geode LSP.
// Split out of features.zig (#806, QUALITY_GAP_ANALYSIS) — features.zig
// remains the public facade re-exporting `provideReferences`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("../protocol.zig");
const Document = @import("../document.zig").Document;
const geode = @import("geode");
const language_metadata = geode.language_metadata;

// ============================================================================
// References Provider
// CANARY: REQ=REQ-LSP-REFS-001; FEATURE="References"; ASPECT=FindAllRefs; STATUS=IMPL; OWNER=lsp; UPDATED=2026-01-27
// ============================================================================

/// Find all references to a symbol in the document
pub fn provideReferences(allocator: Allocator, doc: *const Document, line: u32, character: u32, include_declaration: bool) ![]protocol.Location {
    _ = include_declaration; // We always include declarations in our simple implementation

    const offset = doc.getOffset(line, character) orelse return &[_]protocol.Location{};
    const word = doc.getWordAt(offset) orelse return &[_]protocol.Location{};

    // Skip if it's a keyword, function, or type
    if (language_metadata.findKeyword(word) != null) return &[_]protocol.Location{};
    if (language_metadata.findFunction(word) != null) return &[_]protocol.Location{};
    if (language_metadata.findType(word) != null) return &[_]protocol.Location{};

    var locations = std.ArrayList(protocol.Location).initCapacity(allocator, 16) catch return error.OutOfMemory;
    errdefer locations.deinit(allocator);

    // Text-based search for all occurrences
    var current_line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    var in_string = false;
    var string_char: u8 = 0;

    while (i < doc.text.len) {
        if (doc.text[i] == '\n') {
            current_line += 1;
            line_start = i + 1;
            i += 1;
            continue;
        }

        // Skip strings
        if (!in_string and (doc.text[i] == '\'' or doc.text[i] == '"')) {
            in_string = true;
            string_char = doc.text[i];
            i += 1;
            continue;
        }
        if (in_string) {
            if (doc.text[i] == string_char and (i == 0 or doc.text[i - 1] != '\\')) {
                in_string = false;
            }
            i += 1;
            continue;
        }

        // Skip comments
        if (i + 1 < doc.text.len) {
            if ((doc.text[i] == '-' and doc.text[i + 1] == '-') or
                (doc.text[i] == '/' and doc.text[i + 1] == '/'))
            {
                while (i < doc.text.len and doc.text[i] != '\n') i += 1;
                continue;
            }
            if (doc.text[i] == '/' and doc.text[i + 1] == '*') {
                i += 2;
                while (i + 1 < doc.text.len and !(doc.text[i] == '*' and doc.text[i + 1] == '/')) {
                    if (doc.text[i] == '\n') {
                        current_line += 1;
                        line_start = i + 1;
                    }
                    i += 1;
                }
                i += 2;
                continue;
            }
        }

        // Check for word boundary and match
        if (i + word.len <= doc.text.len) {
            const at_word_start = i == 0 or !std.ascii.isAlphanumeric(doc.text[i - 1]) and doc.text[i - 1] != '_';
            if (at_word_start and std.mem.eql(u8, doc.text[i .. i + word.len], word)) {
                const end_pos = i + word.len;
                const at_word_end = end_pos >= doc.text.len or (!std.ascii.isAlphanumeric(doc.text[end_pos]) and doc.text[end_pos] != '_');

                if (at_word_end) {
                    try locations.append(allocator, .{
                        .uri = doc.uri,
                        .range = .{
                            .start = .{
                                .line = current_line,
                                .character = @intCast(i - line_start),
                            },
                            .end = .{
                                .line = current_line,
                                .character = @intCast(end_pos - line_start),
                            },
                        },
                    });
                    i = end_pos;
                    continue;
                }
            }
        }

        i += 1;
    }

    return locations.toOwnedSlice(allocator);
}
// ============================================================================
// Unit Tests for References
// ============================================================================

test "provideReferences - finds all variable occurrences" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "MATCH (n) WHERE n.age > 21 RETURN n", 1);
    defer doc.deinit();

    // Position at first 'n' (offset ~7)
    const refs = try provideReferences(allocator, doc, 0, 7, true);
    defer allocator.free(refs);

    // Should find 'n' 3 times
    try std.testing.expect(refs.len == 3);
}

test "provideReferences - skips keywords" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "MATCH (n) RETURN n", 1);
    defer doc.deinit();

    // Position at 'MATCH' keyword
    const refs = try provideReferences(allocator, doc, 0, 0, true);
    defer allocator.free(refs);

    // Should return empty for keywords
    try std.testing.expect(refs.len == 0);
}
