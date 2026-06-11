// Document-symbols (outline) provider for the GQL/Geode LSP.
// Split out of features.zig (#806, QUALITY_GAP_ANALYSIS) — features.zig
// remains the public facade re-exporting `provideDocumentSymbols`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("../protocol.zig");
const Document = @import("../document.zig").Document;
const geode = @import("geode");

// ============================================================================
// Document Symbols Provider
// CANARY: REQ=REQ-LSP-SYMBOLS-001; FEATURE="DocumentSymbols"; ASPECT=OutlineView; STATUS=IMPL; OWNER=lsp; UPDATED=2026-01-27
// ============================================================================

/// Provide document symbols for outline view
pub fn provideDocumentSymbols(allocator: Allocator, doc: *const Document) ![]protocol.DocumentSymbol {
    var symbols = std.ArrayList(protocol.DocumentSymbol).initCapacity(allocator, 16) catch return error.OutOfMemory;
    errdefer symbols.deinit(allocator);

    // Try to parse the document
    const outcome = geode.parseGqlOutcome(doc.text, allocator, .{}) catch {
        // Fall back to text-based symbol extraction on parse errors
        return try extractSymbolsFromText(allocator, doc);
    };

    switch (outcome) {
        .Ok => |result| {
            defer {
                var res = result;
                res.deinit();
            }

            // Extract symbols from the AST
            for (result.program.statements) |stmt| {
                try extractSymbolsFromStatement(allocator, &symbols, doc, stmt);
            }
        },
        .Err => {
            // Fall back to text-based extraction
            return try extractSymbolsFromText(allocator, doc);
        },
    }

    return symbols.toOwnedSlice(allocator);
}

fn extractSymbolsFromStatement(allocator: Allocator, symbols: *std.ArrayList(protocol.DocumentSymbol), doc: *const Document, stmt: anytype) !void {
    switch (stmt) {
        .Query => |query| {
            try extractSymbolsFromQuery(allocator, symbols, doc, query);
        },
        .Union => |union_q| {
            try extractSymbolsFromQuery(allocator, symbols, doc, union_q.first);
            for (union_q.tails) |part| {
                try extractSymbolsFromQuery(allocator, symbols, doc, part.query);
            }
        },
        else => {},
    }
}

fn extractSymbolsFromQuery(allocator: Allocator, symbols: *std.ArrayList(protocol.DocumentSymbol), doc: *const Document, query: anytype) !void {
    // Extract from LET bindings
    for (query.let_bindings) |binding| {
        if (findSymbolPosition(doc.text, binding.variable, .let_binding)) |pos| {
            try symbols.append(allocator, .{
                .name = binding.variable,
                .detail = "LET binding",
                .kind = .Variable,
                .range = pos.range,
                .selectionRange = pos.selectionRange,
            });
        }
    }

    for (query.inline_let_bindings) |binding| {
        if (findSymbolPosition(doc.text, binding.variable, .let_binding)) |pos| {
            try symbols.append(allocator, .{
                .name = binding.variable,
                .detail = "LET binding",
                .kind = .Variable,
                .range = pos.range,
                .selectionRange = pos.selectionRange,
            });
        }
    }

    // Extract from MATCH patterns
    for (query.match.chains) |chain| {
        // Path variable
        if (chain.name) |name| {
            if (findSymbolPosition(doc.text, name, .path_pattern)) |pos| {
                try symbols.append(allocator, .{
                    .name = name,
                    .detail = "Path variable",
                    .kind = .Variable,
                    .range = pos.range,
                    .selectionRange = pos.selectionRange,
                });
            }
        }

        // Head node
        if (chain.head) |head| {
            if (head.name) |name| {
                const label_detail = if (head.labels.len > 0)
                    head.labels[0]
                else
                    "Node";
                if (findSymbolPosition(doc.text, name, .node_pattern)) |pos| {
                    try symbols.append(allocator, .{
                        .name = name,
                        .detail = label_detail,
                        .kind = .Variable,
                        .range = pos.range,
                        .selectionRange = pos.selectionRange,
                    });
                }
            }
        }

        // Hops (relationships and nodes)
        for (chain.hops) |hop| {
            // Left node
            if (hop.left.name) |name| {
                const label_detail = if (hop.left.labels.len > 0)
                    hop.left.labels[0]
                else
                    "Node";
                if (findSymbolPosition(doc.text, name, .node_pattern)) |pos| {
                    try symbols.append(allocator, .{
                        .name = name,
                        .detail = label_detail,
                        .kind = .Variable,
                        .range = pos.range,
                        .selectionRange = pos.selectionRange,
                    });
                }
            }

            // Relationship
            if (hop.rel.name) |name| {
                const type_detail = if (hop.rel.types.len > 0)
                    hop.rel.types[0]
                else
                    "Relationship";
                if (findSymbolPosition(doc.text, name, .rel_pattern)) |pos| {
                    try symbols.append(allocator, .{
                        .name = name,
                        .detail = type_detail,
                        .kind = .Property,
                        .range = pos.range,
                        .selectionRange = pos.selectionRange,
                    });
                }
            }

            // Right node
            if (hop.right.name) |name| {
                const label_detail = if (hop.right.labels.len > 0)
                    hop.right.labels[0]
                else
                    "Node";
                if (findSymbolPosition(doc.text, name, .node_pattern)) |pos| {
                    try symbols.append(allocator, .{
                        .name = name,
                        .detail = label_detail,
                        .kind = .Variable,
                        .range = pos.range,
                        .selectionRange = pos.selectionRange,
                    });
                }
            }
        }
    }

    // Extract from WITH clause aliases
    if (query.with_clause) |with| {
        for (with.items) |item| {
            if (item.alias) |alias| {
                if (findSymbolPosition(doc.text, alias, .with_alias)) |pos| {
                    try symbols.append(allocator, .{
                        .name = alias,
                        .detail = "WITH alias",
                        .kind = .Variable,
                        .range = pos.range,
                        .selectionRange = pos.selectionRange,
                    });
                }
            }
        }
    }

    // Extract from RETURN aliases
    for (query.ret.items) |item| {
        if (item.alias) |alias| {
            if (findSymbolPosition(doc.text, alias, .return_alias)) |pos| {
                try symbols.append(allocator, .{
                    .name = alias,
                    .detail = "RETURN alias",
                    .kind = .Variable,
                    .range = pos.range,
                    .selectionRange = pos.selectionRange,
                });
            }
        }
    }

    // Recurse into next query
    if (query.next_query) |next| {
        try extractSymbolsFromQuery(allocator, symbols, doc, next.*);
    }
}

const SymbolSearchType = enum {
    node_pattern,
    rel_pattern,
    path_pattern,
    with_alias,
    return_alias,
    let_binding,
};

const SymbolPositionResult = struct {
    range: protocol.Range,
    selectionRange: protocol.Range,
};

fn findSymbolPosition(text: []const u8, name: []const u8, search_type: SymbolSearchType) ?SymbolPositionResult {
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    var in_string = false;
    var string_char: u8 = 0;

    while (i < text.len) {
        // Track newlines
        if (text[i] == '\n') {
            line += 1;
            line_start = i + 1;
            i += 1;
            continue;
        }

        // Skip strings
        if (!in_string and (text[i] == '\'' or text[i] == '"')) {
            in_string = true;
            string_char = text[i];
            i += 1;
            continue;
        }
        if (in_string) {
            if (text[i] == string_char and (i == 0 or text[i - 1] != '\\')) {
                in_string = false;
            }
            i += 1;
            continue;
        }

        // Check for pattern based on type
        const found_pos: ?usize = switch (search_type) {
            .node_pattern => findNodePatternForSymbol(text, i, name),
            .rel_pattern => findRelPatternForSymbol(text, i, name),
            .path_pattern => findPathPatternForSymbol(text, i, name),
            .with_alias, .return_alias => findAliasPatternForSymbol(text, i, name),
            .let_binding => findLetPatternForSymbol(text, i, name),
        };

        if (found_pos) |pos| {
            const char_start: u32 = @intCast(pos - line_start);
            const char_end: u32 = char_start + @as(u32, @intCast(name.len));
            return SymbolPositionResult{
                .range = .{
                    .start = .{ .line = line, .character = char_start },
                    .end = .{ .line = line, .character = char_end },
                },
                .selectionRange = .{
                    .start = .{ .line = line, .character = char_start },
                    .end = .{ .line = line, .character = char_end },
                },
            };
        }

        i += 1;
    }

    return null;
}

fn findNodePatternForSymbol(text: []const u8, pos: usize, name: []const u8) ?usize {
    if (pos >= text.len or text[pos] != '(') return null;
    var i = pos + 1;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    if (i + name.len > text.len) return null;
    if (!std.mem.eql(u8, text[i .. i + name.len], name)) return null;
    const end = i + name.len;
    if (end >= text.len) return null;
    const next = text[end];
    if (next == ')' or next == ':' or next == ' ' or next == '\t' or next == '{') return i;
    return null;
}

fn findRelPatternForSymbol(text: []const u8, pos: usize, name: []const u8) ?usize {
    if (pos >= text.len or text[pos] != '[') return null;
    var i = pos + 1;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    if (i + name.len > text.len) return null;
    if (!std.mem.eql(u8, text[i .. i + name.len], name)) return null;
    const end = i + name.len;
    if (end >= text.len) return null;
    const next = text[end];
    if (next == ']' or next == ':' or next == ' ' or next == '\t' or next == '{' or next == '*') return i;
    return null;
}

fn findPathPatternForSymbol(text: []const u8, pos: usize, name: []const u8) ?usize {
    // Look for "name = (" pattern
    if (pos + name.len + 3 > text.len) return null;
    if (!std.mem.eql(u8, text[pos .. pos + name.len], name)) return null;
    var i = pos + name.len;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    if (i >= text.len or text[i] != '=') return null;
    i += 1;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    if (i >= text.len or text[i] != '(') return null;
    // Check word boundary before name
    if (pos > 0 and std.ascii.isAlphanumeric(text[pos - 1])) return null;
    return pos;
}

fn findAliasPatternForSymbol(text: []const u8, pos: usize, name: []const u8) ?usize {
    // Look for "AS name" pattern
    if (pos + 2 > text.len) return null;
    if (!std.ascii.eqlIgnoreCase(text[pos .. pos + 2], "AS")) return null;
    var i = pos + 2;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    if (i + name.len > text.len) return null;
    if (!std.mem.eql(u8, text[i .. i + name.len], name)) return null;
    const end = i + name.len;
    if (end < text.len and std.ascii.isAlphanumeric(text[end])) return null;
    return i;
}

fn findLetPatternForSymbol(text: []const u8, pos: usize, name: []const u8) ?usize {
    if (pos + 3 > text.len) return null;
    if (!std.ascii.eqlIgnoreCase(text[pos .. pos + 3], "LET")) return null;
    var i = pos + 3;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    // Skip $ if present
    if (i < text.len and text[i] == '$') i += 1;
    if (i + name.len > text.len) return null;
    if (!std.mem.eql(u8, text[i .. i + name.len], name)) return null;
    const end = i + name.len;
    if (end < text.len and std.ascii.isAlphanumeric(text[end])) return null;
    return i;
}

/// Fallback text-based symbol extraction when parsing fails
fn extractSymbolsFromText(allocator: Allocator, doc: *const Document) ![]protocol.DocumentSymbol {
    var symbols = std.ArrayList(protocol.DocumentSymbol).initCapacity(allocator, 16) catch return error.OutOfMemory;
    errdefer symbols.deinit(allocator);

    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    var in_string = false;
    var string_char: u8 = 0;

    while (i < doc.text.len) {
        if (doc.text[i] == '\n') {
            line += 1;
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

        // Look for (varname pattern
        if (doc.text[i] == '(' and i + 1 < doc.text.len) {
            var j = i + 1;
            while (j < doc.text.len and (doc.text[j] == ' ' or doc.text[j] == '\t')) j += 1;
            if (j < doc.text.len and (std.ascii.isAlphabetic(doc.text[j]) or doc.text[j] == '_')) {
                const name_start = j;
                while (j < doc.text.len and (std.ascii.isAlphanumeric(doc.text[j]) or doc.text[j] == '_')) j += 1;
                const name = doc.text[name_start..j];
                if (name.len > 0 and j < doc.text.len and (doc.text[j] == ')' or doc.text[j] == ':' or doc.text[j] == ' ' or doc.text[j] == '{')) {
                    const char_start: u32 = @intCast(name_start - line_start);
                    const char_end: u32 = char_start + @as(u32, @intCast(name.len));
                    try symbols.append(allocator, .{
                        .name = name,
                        .detail = "Node",
                        .kind = .Variable,
                        .range = .{
                            .start = .{ .line = line, .character = char_start },
                            .end = .{ .line = line, .character = char_end },
                        },
                        .selectionRange = .{
                            .start = .{ .line = line, .character = char_start },
                            .end = .{ .line = line, .character = char_end },
                        },
                    });
                }
            }
        }

        // Look for [varname pattern
        if (doc.text[i] == '[' and i + 1 < doc.text.len) {
            var j = i + 1;
            while (j < doc.text.len and (doc.text[j] == ' ' or doc.text[j] == '\t')) j += 1;
            if (j < doc.text.len and (std.ascii.isAlphabetic(doc.text[j]) or doc.text[j] == '_')) {
                const name_start = j;
                while (j < doc.text.len and (std.ascii.isAlphanumeric(doc.text[j]) or doc.text[j] == '_')) j += 1;
                const name = doc.text[name_start..j];
                if (name.len > 0 and j < doc.text.len and (doc.text[j] == ']' or doc.text[j] == ':' or doc.text[j] == ' ' or doc.text[j] == '{' or doc.text[j] == '*')) {
                    const char_start: u32 = @intCast(name_start - line_start);
                    const char_end: u32 = char_start + @as(u32, @intCast(name.len));
                    try symbols.append(allocator, .{
                        .name = name,
                        .detail = "Relationship",
                        .kind = .Property,
                        .range = .{
                            .start = .{ .line = line, .character = char_start },
                            .end = .{ .line = line, .character = char_end },
                        },
                        .selectionRange = .{
                            .start = .{ .line = line, .character = char_start },
                            .end = .{ .line = line, .character = char_end },
                        },
                    });
                }
            }
        }

        i += 1;
    }

    return symbols.toOwnedSlice(allocator);
}
// ============================================================================
// Unit Tests for Document Symbols
// ============================================================================

test "provideDocumentSymbols - extracts node variables" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "MATCH (n:Person) RETURN n", 1);
    defer doc.deinit();

    const symbols = try provideDocumentSymbols(allocator, doc);
    defer allocator.free(symbols);

    try std.testing.expect(symbols.len >= 1);
    try std.testing.expectEqualStrings("n", symbols[0].name);
    try std.testing.expect(symbols[0].kind == .Variable);
}

test "provideDocumentSymbols - extracts relationship variables" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "MATCH (a)-[r:KNOWS]->(b) RETURN r", 1);
    defer doc.deinit();

    const symbols = try provideDocumentSymbols(allocator, doc);
    defer allocator.free(symbols);

    // Should have at least a, r, b
    try std.testing.expect(symbols.len >= 2);
}

test "provideDocumentSymbols - multiple node patterns" {
    const allocator = std.testing.allocator;
    // Valid GQL with multiple nodes
    const doc = try Document.init(allocator, "file:///test.gql", "MATCH (a:Person)-[r]->(b:Company) RETURN a, b", 1);
    defer doc.deinit();

    const symbols = try provideDocumentSymbols(allocator, doc);
    defer allocator.free(symbols);

    // Should extract multiple symbols
    try std.testing.expect(symbols.len >= 2);
}
