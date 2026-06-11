// Go-to-definition provider for the GQL/Geode LSP.
// Split out of features.zig (#806, QUALITY_GAP_ANALYSIS) — features.zig
// remains the public facade re-exporting `provideDefinition`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("../protocol.zig");
const Document = @import("../document.zig").Document;
const geode = @import("geode");
const language_metadata = geode.language_metadata;

/// GAP-0818: caller identity threaded into every feature provider.
const LspContext = @import("../context.zig").LspContext;

// GAP-0056: LSP Go-To-Definition Implementation
// CANARY: REQ=REQ-LSP-GOTODEF-001; FEATURE="GoToDefinition"; ASPECT=VariableLookup; STATUS=TESTED; OWNER=lsp; UPDATED=2026-05-06
// CANARY: REQ=REQ-LSP-CALLER-IDENTITY-001; FEATURE="LspCallerIdentity"; ASPECT=DefinitionContext; STATUS=TESTED; TEST=tests/test_gap0818_lsp_context.zig:"GAP-0818 definition is tenant-independent variable lookup"; OWNER=lsp; UPDATED=2026-06-09
pub fn provideDefinition(allocator: Allocator, doc: *const Document, line: u32, character: u32, caller: LspContext) !?protocol.Location {
    // GAP-0818: go-to-definition resolves an in-document variable
    // declaration (a pattern variable like `(n:...)`), which is purely a
    // function of the open document text and carries no tenant-scoped
    // schema lookup. The caller identity is threaded for parity with the
    // other providers (audit / telemetry attribution) but does not change
    // the resolution — there is nothing tenant-scoped to leak here.
    _ = caller;
    const offset = doc.getOffset(line, character) orelse return null;
    const word = doc.getWordAt(offset) orelse return null;

    // Skip if the word is a keyword, function, or type - they don't have definitions in user code
    if (language_metadata.findKeyword(word) != null) return null;
    if (language_metadata.findFunction(word) != null) return null;
    if (language_metadata.findType(word) != null) return null;

    // Try parsing the document to find variable definitions
    const outcome = geode.parseGqlOutcome(doc.text, allocator, .{}) catch return null;

    switch (outcome) {
        .Ok => |result| {
            defer {
                var res = result;
                res.deinit();
            }

            // Search for variable definition in the AST
            if (findVariableDefinition(allocator, result.program, word)) |def_info| {
                // Convert text offset to line/column using document
                if (findPositionOfDefinition(doc, def_info.pattern_type, word)) |pos| {
                    return protocol.Location{
                        .uri = doc.uri,
                        .range = .{
                            .start = pos,
                            .end = .{
                                .line = pos.line,
                                .character = pos.character + @as(u32, @intCast(word.len)),
                            },
                        },
                    };
                }
            }
        },
        .Err => {
            // Even with parse errors, try text-based search for patterns
        },
    }

    // Fallback: text-based search for variable patterns like (varname or [varname
    if (findVariablePatternPosition(doc.text, word)) |pos| {
        return protocol.Location{
            .uri = doc.uri,
            .range = .{
                .start = pos,
                .end = .{
                    .line = pos.line,
                    .character = pos.character + @as(u32, @intCast(word.len)),
                },
            },
        };
    }

    return null;
}

/// Definition info from AST analysis
const DefinitionInfo = struct {
    pattern_type: PatternType,
    name: []const u8,
};

const PatternType = enum {
    node_pattern, // (varname) or (varname:Label)
    rel_pattern, // [varname] or [varname:TYPE]
    with_alias, // WITH expr AS varname
    let_binding, // LET varname = expr
    return_alias, // RETURN expr AS varname
};

/// Search AST for variable definitions
fn findVariableDefinition(allocator: Allocator, program: anytype, target: []const u8) ?DefinitionInfo {
    _ = allocator;

    for (program.statements) |stmt| {
        switch (stmt) {
            .Query => |query| {
                if (findVarInQuery(query, target)) |info| {
                    return info;
                }
            },
            .Union => |union_q| {
                if (findVarInQuery(union_q.first, target)) |info| {
                    return info;
                }
                for (union_q.tails) |part| {
                    if (findVarInQuery(part.query, target)) |info| {
                        return info;
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

fn findVarInQuery(query: anytype, target: []const u8) ?DefinitionInfo {
    // Check LET bindings
    for (query.let_bindings) |binding| {
        if (std.mem.eql(u8, binding.variable, target)) {
            return DefinitionInfo{ .pattern_type = .let_binding, .name = target };
        }
    }
    for (query.inline_let_bindings) |binding| {
        if (std.mem.eql(u8, binding.variable, target)) {
            return DefinitionInfo{ .pattern_type = .let_binding, .name = target };
        }
    }

    // Check MATCH pattern for node and relationship variables
    for (query.match.chains) |chain| {
        // Check chain name (path variable)
        if (chain.name) |name| {
            if (std.mem.eql(u8, name, target)) {
                return DefinitionInfo{ .pattern_type = .node_pattern, .name = target };
            }
        }

        // Check head node pattern
        if (chain.head) |head| {
            if (head.name) |name| {
                if (std.mem.eql(u8, name, target)) {
                    return DefinitionInfo{ .pattern_type = .node_pattern, .name = target };
                }
            }
        }

        // Check hops
        for (chain.hops) |hop| {
            if (hop.left.name) |name| {
                if (std.mem.eql(u8, name, target)) {
                    return DefinitionInfo{ .pattern_type = .node_pattern, .name = target };
                }
            }
            if (hop.rel.name) |name| {
                if (std.mem.eql(u8, name, target)) {
                    return DefinitionInfo{ .pattern_type = .rel_pattern, .name = target };
                }
            }
            if (hop.right.name) |name| {
                if (std.mem.eql(u8, name, target)) {
                    return DefinitionInfo{ .pattern_type = .node_pattern, .name = target };
                }
            }
        }
    }

    // Check WITH clause aliases
    if (query.with_clause) |with| {
        for (with.items) |item| {
            if (item.alias) |alias| {
                if (std.mem.eql(u8, alias, target)) {
                    return DefinitionInfo{ .pattern_type = .with_alias, .name = target };
                }
            }
        }
    }

    // Check RETURN aliases (for definitions later referenced)
    for (query.ret.items) |item| {
        if (item.alias) |alias| {
            if (std.mem.eql(u8, alias, target)) {
                return DefinitionInfo{ .pattern_type = .return_alias, .name = target };
            }
        }
    }

    // Check next_query for chained queries
    if (query.next_query) |next| {
        if (findVarInQuery(next.*, target)) |info| {
            return info;
        }
    }

    return null;
}

/// Find position of a variable definition based on pattern type
fn findPositionOfDefinition(doc: *const Document, pattern_type: PatternType, name: []const u8) ?protocol.Position {
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;

    while (i < doc.text.len) {
        // Track newlines
        if (doc.text[i] == '\n') {
            line += 1;
            line_start = i + 1;
            i += 1;
            continue;
        }

        // Skip string literals
        if (doc.text[i] == '\'' or doc.text[i] == '"') {
            const quote = doc.text[i];
            i += 1;
            while (i < doc.text.len and doc.text[i] != quote) {
                if (doc.text[i] == '\n') {
                    line += 1;
                    line_start = i + 1;
                }
                i += 1;
            }
            if (i < doc.text.len) i += 1;
            continue;
        }

        // Look for pattern based on type
        const found = switch (pattern_type) {
            .node_pattern => findNodePatternStart(doc.text, i, name),
            .rel_pattern => findRelPatternStart(doc.text, i, name),
            .with_alias => findAliasPosition(doc.text, i, name, "AS"),
            .let_binding => findLetBindingPosition(doc.text, i, name),
            .return_alias => findAliasPosition(doc.text, i, name, "AS"),
        };

        if (found) |offset| {
            return protocol.Position{
                .line = line,
                .character = @intCast(offset - line_start),
            };
        }

        i += 1;
    }

    return null;
}

fn findNodePatternStart(text: []const u8, pos: usize, name: []const u8) ?usize {
    // Look for (name or (name: or (name)
    if (pos >= text.len or text[pos] != '(') return null;
    if (pos + 1 + name.len > text.len) return null;

    const start = pos + 1;
    // Skip whitespace
    var i = start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) {
        i += 1;
    }

    if (i + name.len > text.len) return null;

    // Check for name match
    if (std.mem.eql(u8, text[i .. i + name.len], name)) {
        const end = i + name.len;
        // Must be followed by ) or : or whitespace
        if (end >= text.len) return null;
        const next = text[end];
        if (next == ')' or next == ':' or next == ' ' or next == '\t' or next == '{') {
            return i;
        }
    }
    return null;
}

fn findRelPatternStart(text: []const u8, pos: usize, name: []const u8) ?usize {
    // Look for [name or [name: or [name]
    if (pos >= text.len or text[pos] != '[') return null;
    if (pos + 1 + name.len > text.len) return null;

    const start = pos + 1;
    var i = start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) {
        i += 1;
    }

    if (i + name.len > text.len) return null;

    if (std.mem.eql(u8, text[i .. i + name.len], name)) {
        const end = i + name.len;
        if (end >= text.len) return null;
        const next = text[end];
        if (next == ']' or next == ':' or next == ' ' or next == '\t' or next == '{' or next == '*') {
            return i;
        }
    }
    return null;
}

fn findAliasPosition(text: []const u8, pos: usize, name: []const u8, keyword: []const u8) ?usize {
    // Look for "AS name" pattern
    if (pos + keyword.len + 1 + name.len > text.len) return null;

    // Check for AS keyword (case insensitive)
    if (!std.ascii.eqlIgnoreCase(text[pos .. pos + keyword.len], keyword)) return null;

    var i = pos + keyword.len;
    // Skip whitespace
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) {
        i += 1;
    }

    if (i + name.len > text.len) return null;

    if (std.mem.eql(u8, text[i .. i + name.len], name)) {
        const end = i + name.len;
        // Must be at end or followed by non-identifier char
        if (end >= text.len or !std.ascii.isAlphanumeric(text[end])) {
            return i;
        }
    }
    return null;
}

fn findLetBindingPosition(text: []const u8, pos: usize, name: []const u8) ?usize {
    // Look for "LET name" or "LET $name" pattern
    if (pos + 3 > text.len) return null;

    if (!std.ascii.eqlIgnoreCase(text[pos .. pos + 3], "LET")) return null;

    var i = pos + 3;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) {
        i += 1;
    }

    // Skip $ prefix if present
    if (i < text.len and text[i] == '$') {
        i += 1;
    }

    if (i + name.len > text.len) return null;

    if (std.mem.eql(u8, text[i .. i + name.len], name)) {
        const end = i + name.len;
        if (end >= text.len or !std.ascii.isAlphanumeric(text[end])) {
            return i;
        }
    }
    return null;
}

/// Fallback text-based search for variable patterns
fn findVariablePatternPosition(text: []const u8, name: []const u8) ?protocol.Position {
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;

    while (i < text.len) {
        if (text[i] == '\n') {
            line += 1;
            line_start = i + 1;
            i += 1;
            continue;
        }

        // Check for (name pattern
        if (text[i] == '(' and i + 1 + name.len <= text.len) {
            const start = i + 1;
            if (std.mem.eql(u8, text[start .. start + name.len], name)) {
                const end = start + name.len;
                if (end >= text.len or text[end] == ')' or text[end] == ':' or text[end] == ' ' or text[end] == '{') {
                    return protocol.Position{
                        .line = line,
                        .character = @intCast(start - line_start),
                    };
                }
            }
        }

        // Check for [name pattern
        if (text[i] == '[' and i + 1 + name.len <= text.len) {
            const start = i + 1;
            if (std.mem.eql(u8, text[start .. start + name.len], name)) {
                const end = start + name.len;
                if (end >= text.len or text[end] == ']' or text[end] == ':' or text[end] == ' ' or text[end] == '{' or text[end] == '*') {
                    return protocol.Position{
                        .line = line,
                        .character = @intCast(start - line_start),
                    };
                }
            }
        }

        i += 1;
    }

    return null;
}
