// Semantic-tokens provider for the GQL/Geode LSP.
// Split out of features.zig (#806, QUALITY_GAP_ANALYSIS) — features.zig
// remains the public facade re-exporting `provideSemanticTokensFull`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("../protocol.zig");
const Document = @import("../document.zig").Document;
const geode = @import("geode");
const language_metadata = geode.language_metadata;

// ============================================================================
// Semantic Tokens Provider
// CANARY: REQ=REQ-LSP-SEMTOK-001; FEATURE="SemanticTokens"; ASPECT=SyntaxHighlight; STATUS=IMPL; OWNER=lsp; UPDATED=2026-01-27
// ============================================================================

/// Token types for semantic highlighting
const TokenType = enum(u32) {
    keyword = 0,
    function = 1,
    variable = 2,
    parameter = 3,
    type_ = 4,
    property = 5,
    string = 6,
    number = 7,
    comment = 8,
    operator = 9,
    label = 10,
};

/// Token modifiers for semantic highlighting
const TokenModifier = enum(u32) {
    definition = 0,
    defaultLibrary = 1,
    readonly = 2,
};

/// Provide semantic tokens for syntax highlighting
pub fn provideSemanticTokensFull(allocator: Allocator, doc: *const Document) !protocol.SemanticTokens {
    var tokens = std.ArrayList(u32).initCapacity(allocator, 256) catch return error.OutOfMemory;
    errdefer tokens.deinit(allocator);

    var prev_line: u32 = 0;
    var prev_char: u32 = 0;
    var current_line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;

    // Track defined variables for definition modifier
    var defined_vars = std.StringHashMap(void).init(allocator);
    defer defined_vars.deinit();

    while (i < doc.text.len) {
        if (doc.text[i] == '\n') {
            current_line += 1;
            line_start = i + 1;
            i += 1;
            continue;
        }

        // Handle comments
        if (i + 1 < doc.text.len) {
            if ((doc.text[i] == '-' and doc.text[i + 1] == '-') or
                (doc.text[i] == '/' and doc.text[i + 1] == '/'))
            {
                const start_char: u32 = @intCast(i - line_start);
                const comment_start = i;
                while (i < doc.text.len and doc.text[i] != '\n') i += 1;
                const comment_len: u32 = @intCast(i - comment_start);

                try addToken(allocator, &tokens, current_line, start_char, comment_len, .comment, 0, &prev_line, &prev_char);
                continue;
            }
            if (doc.text[i] == '/' and doc.text[i + 1] == '*') {
                const start_line = current_line;
                const start_char: u32 = @intCast(i - line_start);
                const comment_start = i;
                i += 2;
                while (i + 1 < doc.text.len and !(doc.text[i] == '*' and doc.text[i + 1] == '/')) {
                    if (doc.text[i] == '\n') {
                        current_line += 1;
                        line_start = i + 1;
                    }
                    i += 1;
                }
                if (i + 1 < doc.text.len) i += 2;

                // For multi-line comments, only emit one token for first line
                if (start_line == current_line) {
                    const comment_len: u32 = @intCast(i - comment_start);
                    try addToken(allocator, &tokens, start_line, start_char, comment_len, .comment, 0, &prev_line, &prev_char);
                }
                continue;
            }
        }

        // Handle strings
        if (doc.text[i] == '\'' or doc.text[i] == '"') {
            const quote = doc.text[i];
            const start_char: u32 = @intCast(i - line_start);
            const string_start = i;
            i += 1;
            while (i < doc.text.len and doc.text[i] != quote) {
                if (doc.text[i] == '\\' and i + 1 < doc.text.len) {
                    i += 2;
                } else if (doc.text[i] == '\n') {
                    // Multi-line string - emit token for current line only
                    const string_len: u32 = @intCast(i - string_start);
                    try addToken(allocator, &tokens, current_line, start_char, string_len, .string, 0, &prev_line, &prev_char);
                    current_line += 1;
                    line_start = i + 1;
                    i += 1;
                    continue;
                } else {
                    i += 1;
                }
            }
            if (i < doc.text.len) i += 1;
            const string_len: u32 = @intCast(i - string_start);
            try addToken(allocator, &tokens, current_line, start_char, string_len, .string, 0, &prev_line, &prev_char);
            continue;
        }

        // Handle parameters ($name)
        if (doc.text[i] == '$') {
            const start_char: u32 = @intCast(i - line_start);
            const param_start = i;
            i += 1;
            while (i < doc.text.len and (std.ascii.isAlphanumeric(doc.text[i]) or doc.text[i] == '_')) {
                i += 1;
            }
            const param_len: u32 = @intCast(i - param_start);
            if (param_len > 1) {
                try addToken(allocator, &tokens, current_line, start_char, param_len, .parameter, 0, &prev_line, &prev_char);
            }
            continue;
        }

        // Handle numbers
        if (std.ascii.isDigit(doc.text[i]) or (doc.text[i] == '.' and i + 1 < doc.text.len and std.ascii.isDigit(doc.text[i + 1]))) {
            const start_char: u32 = @intCast(i - line_start);
            const num_start = i;
            // Integer or float
            while (i < doc.text.len and (std.ascii.isDigit(doc.text[i]) or doc.text[i] == '.' or doc.text[i] == 'e' or doc.text[i] == 'E' or doc.text[i] == '-' or doc.text[i] == '+')) {
                i += 1;
            }
            const num_len: u32 = @intCast(i - num_start);
            try addToken(allocator, &tokens, current_line, start_char, num_len, .number, 0, &prev_line, &prev_char);
            continue;
        }

        // Handle identifiers
        if (std.ascii.isAlphabetic(doc.text[i]) or doc.text[i] == '_') {
            const start_char: u32 = @intCast(i - line_start);
            const id_start = i;
            while (i < doc.text.len and (std.ascii.isAlphanumeric(doc.text[i]) or doc.text[i] == '_')) {
                i += 1;
            }
            const identifier = doc.text[id_start..i];
            const id_len: u32 = @intCast(identifier.len);

            // Check if it's a label (preceded by colon in node/rel pattern)
            var is_label = false;
            if (id_start > 0) {
                var j = id_start - 1;
                while (j > 0 and (doc.text[j] == ' ' or doc.text[j] == '\t')) j -= 1;
                if (doc.text[j] == ':') {
                    // Check if we're in a node or relationship pattern
                    var k = j;
                    while (k > 0) {
                        k -= 1;
                        if (doc.text[k] == '(' or doc.text[k] == '[') {
                            is_label = true;
                            break;
                        }
                        if (doc.text[k] == ')' or doc.text[k] == ']' or doc.text[k] == '\n') {
                            break;
                        }
                    }
                }
            }

            if (is_label) {
                try addToken(allocator, &tokens, current_line, start_char, id_len, .label, 0, &prev_line, &prev_char);
            } else if (language_metadata.findFunction(identifier) != null) {
                // Function - check if followed by (
                var j = i;
                while (j < doc.text.len and (doc.text[j] == ' ' or doc.text[j] == '\t')) j += 1;
                if (j < doc.text.len and doc.text[j] == '(') {
                    try addToken(allocator, &tokens, current_line, start_char, id_len, .function, 1 << @intFromEnum(TokenModifier.defaultLibrary), &prev_line, &prev_char);
                } else {
                    // Could be a variable named same as function
                    try addToken(allocator, &tokens, current_line, start_char, id_len, .variable, 0, &prev_line, &prev_char);
                }
            } else if (language_metadata.findKeyword(identifier) != null) {
                try addToken(allocator, &tokens, current_line, start_char, id_len, .keyword, 0, &prev_line, &prev_char);
            } else if (language_metadata.findType(identifier) != null) {
                try addToken(allocator, &tokens, current_line, start_char, id_len, .type_, 0, &prev_line, &prev_char);
            } else {
                // Check if this is a variable definition (in node/rel pattern or after AS)
                var is_definition = false;
                if (id_start > 0) {
                    var j = id_start - 1;
                    while (j > 0 and (doc.text[j] == ' ' or doc.text[j] == '\t')) j -= 1;
                    if (doc.text[j] == '(' or doc.text[j] == '[') {
                        is_definition = !defined_vars.contains(identifier);
                    }
                }

                // Check if it's a property access (preceded by .)
                var is_property = false;
                if (id_start > 0) {
                    var j = id_start - 1;
                    while (j > 0 and (doc.text[j] == ' ' or doc.text[j] == '\t')) j -= 1;
                    if (doc.text[j] == '.') {
                        is_property = true;
                    }
                }

                if (is_property) {
                    try addToken(allocator, &tokens, current_line, start_char, id_len, .property, 0, &prev_line, &prev_char);
                } else {
                    const modifier: u32 = if (is_definition) 1 << @intFromEnum(TokenModifier.definition) else 0;
                    if (is_definition) {
                        try defined_vars.put(identifier, {});
                    }
                    try addToken(allocator, &tokens, current_line, start_char, id_len, .variable, modifier, &prev_line, &prev_char);
                }
            }
            continue;
        }

        i += 1;
    }

    return protocol.SemanticTokens{
        .data = try tokens.toOwnedSlice(allocator),
    };
}

fn addToken(
    allocator: Allocator,
    tokens: *std.ArrayList(u32),
    line: u32,
    char: u32,
    length: u32,
    token_type: TokenType,
    modifiers: u32,
    prev_line: *u32,
    prev_char: *u32,
) !void {
    const delta_line = line - prev_line.*;
    const delta_char = if (delta_line == 0) char - prev_char.* else char;

    try tokens.append(allocator, delta_line);
    try tokens.append(allocator, delta_char);
    try tokens.append(allocator, length);
    try tokens.append(allocator, @intFromEnum(token_type));
    try tokens.append(allocator, modifiers);

    prev_line.* = line;
    prev_char.* = char;
}
// ============================================================================
// Unit Tests for Semantic Tokens
// ============================================================================

test "provideSemanticTokensFull - basic tokens" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "MATCH (n) RETURN n", 1);
    defer doc.deinit();

    const tokens = try provideSemanticTokensFull(allocator, doc);
    defer allocator.free(tokens.data);

    // Should have tokens - data is delta-encoded in groups of 5
    try std.testing.expect(tokens.data.len > 0);
    try std.testing.expect(tokens.data.len % 5 == 0);
}

test "provideSemanticTokensFull - parameters" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "RETURN $param", 1);
    defer doc.deinit();

    const tokens = try provideSemanticTokensFull(allocator, doc);
    defer allocator.free(tokens.data);

    // Should have at least 2 tokens (RETURN keyword, $param parameter)
    try std.testing.expect(tokens.data.len >= 10);
}

test "provideSemanticTokensFull - comments" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "// comment\nRETURN 1", 1);
    defer doc.deinit();

    const tokens = try provideSemanticTokensFull(allocator, doc);
    defer allocator.free(tokens.data);

    // Should have tokens for comment and RETURN keyword
    try std.testing.expect(tokens.data.len >= 10);
}
