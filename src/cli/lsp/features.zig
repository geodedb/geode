// Module implementation
// CANARY: REQ=REQ-LSP-METADATA-001; FEATURE="MetadataIntegration"; ASPECT=Completions; STATUS=EXEMPT; OWNER=lsp; UPDATED=2026-01-03
// Language features implementation for GQL/Geode LSP

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const Document = @import("document.zig").Document;
const geode = @import("geode");
const semantic = @import("semantic.zig");
const language_metadata = geode.language_metadata;

/// Formatting options for the GQL formatter
pub const FormattingOptions = struct {
    /// Number of spaces for indentation (default: 4)
    indent_size: u32 = 4,
    /// Whether to fold property maps onto multiple lines (default: true)
    fold_property_maps: bool = true,
    /// Maximum line length before folding (default: 80)
    max_line_length: u32 = 80,
    /// Minimum number of properties to trigger folding (default: 2)
    min_properties_to_fold: u32 = 2,
};

// CANARY: REQ=REQ-LSP-METADATA-002; FEATURE="MetadataIntegration"; ASPECT=ComptimeLists; STATUS=EXEMPT; OWNER=lsp; UPDATED=2026-01-03
// GQL Keywords, Functions, and Types derived from unified language_metadata.zig
// This ensures the LSP completions stay in sync with the lexer and documentation
const GQL_KEYWORDS = language_metadata.getKeywordNames();
const GQL_FUNCTIONS = language_metadata.getFunctionNames();
const GQL_TYPES = language_metadata.getTypeNames();

pub fn provideDiagnostics(allocator: Allocator, doc: *const Document) ![]protocol.Diagnostic {
    var diagnostics = std.ArrayList(protocol.Diagnostic).initCapacity(allocator, 10) catch return error.OutOfMemory;
    errdefer diagnostics.deinit(allocator);

    // Parse the document using outcome to get better error info
    const outcome = try geode.parseGqlOutcome(doc.text, allocator, .{});

    switch (outcome) {
        .Err => |err_info| {
            // Check for double-dash comments first (GB02 warning)
            if (err_info.has_double_dash_comment) {
                const warning = protocol.Diagnostic{
                    .range = .{
                        .start = .{ .line = 0, .character = 0 },
                        .end = .{ .line = 0, .character = 0 },
                    },
                    .severity = .Warning,
                    .source = "geode",
                    .message = try allocator.dupe(u8, "Double-dash (--) comments are disabled per GQL spec (GB02). Use // comments instead."),
                };
                try diagnostics.append(allocator, warning);
            }

            // Then show the parse error at the actual location
            const diag = protocol.Diagnostic{
                .range = .{
                    .start = .{ .line = err_info.line, .character = err_info.column },
                    .end = .{ .line = err_info.line, .character = err_info.column + 1 },
                },
                .severity = .Error,
                .source = "geode",
                .message = try allocator.dupe(u8, err_info.msg),
            };
            try diagnostics.append(allocator, diag);
        },
        .Ok => |result| {
            defer {
                var res = result;
                res.deinit();
            }

            // Check for double-dash comments (GB02 - show as warning)
            if (result.has_double_dash_comment) {
                const diag = protocol.Diagnostic{
                    .range = .{
                        .start = .{ .line = 0, .character = 0 },
                        .end = .{ .line = 0, .character = 0 },
                    },
                    .severity = .Warning,
                    .source = "geode",
                    .message = try allocator.dupe(u8, "Double-dash (--) comments are disabled per GQL spec (GB02). Use // comments instead."),
                };
                try diagnostics.append(allocator, diag);
            }

            // Check for parser errors
            if (result.last_error) |last_err| {
                const diag = protocol.Diagnostic{
                    .range = .{
                        .start = .{ .line = 0, .character = 0 },
                        .end = .{ .line = 0, .character = 0 },
                    },
                    .severity = .Error,
                    .source = "geode",
                    .message = try allocator.dupe(u8, last_err),
                };
                try diagnostics.append(allocator, diag);
            }

            // Perform semantic analysis for undefined variable detection
            var analyzer = semantic.SemanticAnalyzer.init(allocator);
            defer analyzer.deinit();

            const sem_errors = analyzer.analyze(result.program) catch {
                // If semantic analysis fails, return existing diagnostics
                return diagnostics.toOwnedSlice(allocator);
            };

            for (sem_errors) |sem_err| {
                // Try to find the position of the undefined variable in the document
                var line = sem_err.line;
                var column = sem_err.column;
                var end_column = sem_err.column + 1;

                // Extract variable name from error message like "Undefined variable: xyz"
                const prefix = "Undefined variable: ";
                if (std.mem.startsWith(u8, sem_err.message, prefix)) {
                    const var_name = sem_err.message[prefix.len..];
                    if (doc.findIdentifierPosition(var_name)) |pos| {
                        line = pos.line;
                        column = pos.character;
                        end_column = pos.character + @as(u32, @intCast(var_name.len));
                    }
                }

                const diag = protocol.Diagnostic{
                    .range = .{
                        .start = .{ .line = line, .character = column },
                        .end = .{ .line = line, .character = end_column },
                    },
                    .severity = .Error,
                    .source = "geode",
                    .message = try allocator.dupe(u8, sem_err.message),
                };
                try diagnostics.append(allocator, diag);
            }
        },
    }

    return diagnostics.toOwnedSlice(allocator);
}

// CANARY: REQ=REQ-LSP-METADATA-003; FEATURE="MetadataIntegration"; ASPECT=Hover; STATUS=EXEMPT; OWNER=lsp; UPDATED=2026-01-03
pub fn provideHover(allocator: Allocator, doc: *const Document, line: u32, character: u32) !?protocol.Hover {
    const offset = doc.getOffset(line, character) orelse return null;
    const word = doc.getWordAt(offset) orelse return null;

    // Check if it's a function (case-sensitive) - check before keywords to avoid
    // false matches like "count" matching keyword "COUNT" instead of function "count"
    if (language_metadata.findFunction(word)) |fn_info| {
        const doc_text = try formatFunctionHover(allocator, fn_info);
        return protocol.Hover{
            .contents = .{
                .kind = .markdown,
                .value = doc_text,
            },
        };
    }

    // Check if it's a keyword (case-insensitive)
    if (language_metadata.findKeyword(word)) |kw_info| {
        const doc_text = try formatKeywordHover(allocator, kw_info);
        return protocol.Hover{
            .contents = .{
                .kind = .markdown,
                .value = doc_text,
            },
        };
    }

    // Check if it's a type (case-insensitive)
    if (language_metadata.findType(word)) |type_info| {
        const doc_text = try formatTypeHover(allocator, type_info);
        return protocol.Hover{
            .contents = .{
                .kind = .markdown,
                .value = doc_text,
            },
        };
    }

    // Check if it's a procedure
    if (language_metadata.findProcedure(word)) |proc_info| {
        const doc_text = try formatProcedureHover(allocator, proc_info);
        return protocol.Hover{
            .contents = .{
                .kind = .markdown,
                .value = doc_text,
            },
        };
    }

    return null;
}

/// Format keyword metadata for hover display
fn formatKeywordHover(allocator: Allocator, info: language_metadata.KeywordInfo) ![]const u8 {
    const compliance = switch (info.compliance) {
        .iso_gql => "ISO/IEC 39075:2024",
        .geode_extension => "Geode Extension",
        .cypher_compat => "Cypher Compatibility",
    };
    const category = @tagName(info.category);

    if (info.extended_doc) |ext| {
        return try std.fmt.allocPrint(allocator,
            \\### `{s}` (Keyword)
            \\
            \\**Category**: {s}
            \\**Compliance**: {s}
            \\
            \\{s}
            \\
            \\---
            \\{s}
        , .{ info.name, category, compliance, info.doc, ext });
    } else {
        return try std.fmt.allocPrint(allocator,
            \\### `{s}` (Keyword)
            \\
            \\**Category**: {s}
            \\**Compliance**: {s}
            \\
            \\{s}
        , .{ info.name, category, compliance, info.doc });
    }
}

/// Format function metadata for hover display
fn formatFunctionHover(allocator: Allocator, info: language_metadata.FunctionInfo) ![]const u8 {
    const category = @tagName(info.category);
    var params_buf = std.ArrayList(u8).initCapacity(allocator, 64) catch return error.OutOfMemory;
    defer params_buf.deinit(allocator);

    // Build parameter list
    for (info.params, 0..) |param, i| {
        if (i > 0) try params_buf.appendSlice(allocator, ", ");
        try params_buf.appendSlice(allocator, param.name);
        try params_buf.appendSlice(allocator, ": ");
        try params_buf.appendSlice(allocator, param.type_name);
        if (param.optional) try params_buf.appendSlice(allocator, "?");
    }

    if (info.example) |example| {
        return try std.fmt.allocPrint(allocator,
            \\### `{s}({s})` → {s}
            \\
            \\**Category**: {s}
            \\
            \\{s}
            \\
            \\**Example**:
            \\```gql
            \\{s}
            \\```
        , .{ info.name, params_buf.items, info.return_type, category, info.doc, example });
    } else {
        return try std.fmt.allocPrint(allocator,
            \\### `{s}({s})` → {s}
            \\
            \\**Category**: {s}
            \\
            \\{s}
        , .{ info.name, params_buf.items, info.return_type, category, info.doc });
    }
}

/// Format type metadata for hover display
fn formatTypeHover(allocator: Allocator, info: language_metadata.TypeInfo) ![]const u8 {
    const compliance = switch (info.compliance) {
        .iso_gql => "ISO/IEC 39075:2024",
        .geode_extension => "Geode Extension",
        .cypher_compat => "Cypher Compatibility",
    };
    if (info.example) |example| {
        return try std.fmt.allocPrint(allocator,
            \\### `{s}` (Type)
            \\
            \\**Compliance**: {s}
            \\
            \\{s}
            \\
            \\**Example**: `{s}`
        , .{ info.name, compliance, info.doc, example });
    } else {
        return try std.fmt.allocPrint(allocator,
            \\### `{s}` (Type)
            \\
            \\**Compliance**: {s}
            \\
            \\{s}
        , .{ info.name, compliance, info.doc });
    }
}

/// Format procedure metadata for hover display
fn formatProcedureHover(allocator: Allocator, info: language_metadata.ProcedureInfo) ![]const u8 {
    const category = @tagName(info.category);
    var yields_buf = std.ArrayList(u8).initCapacity(allocator, 64) catch return error.OutOfMemory;
    defer yields_buf.deinit(allocator);

    // Build yield columns list
    for (info.columns, 0..) |col, i| {
        if (i > 0) try yields_buf.appendSlice(allocator, ", ");
        try yields_buf.appendSlice(allocator, col.name);
        try yields_buf.appendSlice(allocator, ": ");
        try yields_buf.appendSlice(allocator, col.type_name);
    }

    return try std.fmt.allocPrint(allocator,
        \\### `CALL {s}()` → YIELD {s}
        \\
        \\**Category**: {s}
        \\
        \\{s}
    , .{ info.name, yields_buf.items, category, info.doc });
}

// CANARY: REQ=REQ-LSP-METADATA-004; FEATURE="MetadataIntegration"; ASPECT=Completions; STATUS=EXEMPT; OWNER=lsp; UPDATED=2026-01-03
pub fn provideCompletion(allocator: Allocator, doc: *const Document, line: u32, character: u32) ![]protocol.CompletionItem {
    _ = doc;
    _ = line;
    _ = character;

    var items = std.ArrayList(protocol.CompletionItem).initCapacity(allocator, 200) catch return error.OutOfMemory;
    errdefer items.deinit(allocator);

    // Add keywords with metadata documentation
    for (language_metadata.keywords) |kw| {
        const compliance_str = switch (kw.compliance) {
            .iso_gql => " (ISO GQL)",
            .geode_extension => " (Geode)",
            .cypher_compat => " (Cypher)",
        };
        try items.append(allocator, .{
            .label = kw.name,
            .kind = .Keyword,
            .detail = try std.fmt.allocPrint(allocator, "{s}{s}", .{ @tagName(kw.category), compliance_str }),
            .documentation = kw.doc,
            .insertText = kw.name,
        });
    }

    // Add functions with metadata documentation
    for (language_metadata.functions) |func| {
        try items.append(allocator, .{
            .label = func.name,
            .kind = .Function,
            .detail = try std.fmt.allocPrint(allocator, "({s}) → {s}", .{ @tagName(func.category), func.return_type }),
            .documentation = func.doc,
            .insertText = try std.fmt.allocPrint(allocator, "{s}()", .{func.name}),
        });
    }

    // Add types with metadata documentation
    for (language_metadata.types) |typ| {
        const compliance_str = switch (typ.compliance) {
            .iso_gql => "ISO GQL Type",
            .geode_extension => "Geode Type",
            .cypher_compat => "Cypher Type",
        };
        try items.append(allocator, .{
            .label = typ.name,
            .kind = .Class,
            .detail = compliance_str,
            .documentation = typ.doc,
            .insertText = typ.name,
        });
    }

    // Add procedures with metadata documentation
    for (language_metadata.procedures) |proc| {
        try items.append(allocator, .{
            .label = proc.name,
            .kind = .Method,
            .detail = try std.fmt.allocPrint(allocator, "CALL {s}()", .{proc.name}),
            .documentation = proc.doc,
            .insertText = try std.fmt.allocPrint(allocator, "CALL {s}() YIELD", .{proc.name}),
        });
    }

    return items.toOwnedSlice(allocator);
}

// GAP-0056: LSP Go-To-Definition Implementation
// CANARY: REQ=REQ-LSP-GOTODEF-001; FEATURE="GoToDefinition"; ASPECT=VariableLookup; STATUS=EXEMPT; OWNER=lsp; UPDATED=2026-01-10
pub fn provideDefinition(allocator: Allocator, doc: *const Document, line: u32, character: u32) !?protocol.Location {
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

/// Format a GQL document with proper keyword casing, indentation, and spacing.
/// If options is null, uses default options (which enables property map folding).
pub fn provideFormatting(allocator: Allocator, doc: *const Document) !?[]const u8 {
    return provideFormattingWithOptions(allocator, doc, .{});
}

/// Format a GQL document with custom formatting options.
pub fn provideFormattingWithOptions(allocator: Allocator, doc: *const Document, options: FormattingOptions) !?[]const u8 {
    const text = doc.text;
    if (text.len == 0) return null;

    // First pass: basic formatting (keyword casing, newlines before clauses, statement separation)
    const basic_formatted = try formatBasic(allocator, text) orelse return null;
    defer allocator.free(basic_formatted);

    // Second pass: fold property maps if enabled
    const folded = if (options.fold_property_maps)
        try foldPropertyMaps(allocator, basic_formatted, options)
    else
        try allocator.dupe(u8, basic_formatted);
    defer allocator.free(folded);

    // Third pass: apply proper indentation (CASE/WHEN, multi-line RETURN, subqueries)
    return try applyIndentation(allocator, folded, options.indent_size);
}

/// Fold property maps onto multiple lines for better readability.
fn foldPropertyMaps(allocator: Allocator, text: []const u8, options: FormattingOptions) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, text.len * 2);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    var current_indent: usize = 0;
    var in_string = false;
    var string_char: u8 = 0;

    while (i < text.len) {
        const c = text[i];

        // Track indentation at start of lines
        if (i == 0 or (i > 0 and text[i - 1] == '\n')) {
            current_indent = 0;
            var j = i;
            while (j < text.len and text[j] == ' ') : (j += 1) {
                current_indent += 1;
            }
        }

        // Handle string literals
        if (!in_string and (c == '\'' or c == '"')) {
            in_string = true;
            string_char = c;
            try result.append(allocator, c);
            i += 1;
            continue;
        }

        if (in_string) {
            try result.append(allocator, c);
            if (c == string_char and (i == 0 or text[i - 1] != '\\')) {
                in_string = false;
            }
            i += 1;
            continue;
        }

        // Handle property maps
        if (c == '{') {
            // Find matching closing brace
            const brace_end = findMatchingBrace(text, i);
            if (brace_end) |end| {
                const property_map = text[i .. end + 1];
                const property_count = countProperties(property_map);

                // Check if we should fold this property map
                const should_fold = property_count >= options.min_properties_to_fold or
                    (result.items.len > 0 and getLineLength(result.items) + property_map.len > options.max_line_length);

                if (should_fold and property_count > 0) {
                    // Fold the property map
                    try foldPropertyMap(allocator, &result, property_map, current_indent, options);
                    i = end + 1;
                    continue;
                }
            }
        }

        try result.append(allocator, c);
        i += 1;
    }

    return try result.toOwnedSlice(allocator);
}

/// Find the matching closing brace for an opening brace.
fn findMatchingBrace(text: []const u8, start: usize) ?usize {
    if (start >= text.len or text[start] != '{') return null;

    var depth: usize = 0;
    var i = start;
    var in_string = false;
    var string_char: u8 = 0;

    while (i < text.len) {
        const c = text[i];

        if (!in_string and (c == '\'' or c == '"')) {
            in_string = true;
            string_char = c;
        } else if (in_string and c == string_char and (i == 0 or text[i - 1] != '\\')) {
            in_string = false;
        } else if (!in_string) {
            if (c == '{') depth += 1;
            if (c == '}') {
                depth -= 1;
                if (depth == 0) return i;
            }
        }
        i += 1;
    }
    return null;
}

/// Count the number of properties in a property map.
fn countProperties(property_map: []const u8) usize {
    if (property_map.len < 2) return 0;

    var count: usize = 0;
    var in_string = false;
    var string_char: u8 = 0;
    var depth: usize = 0;
    var has_content = false;

    for (property_map, 0..) |c, i| {
        if (!in_string and (c == '\'' or c == '"')) {
            in_string = true;
            string_char = c;
            has_content = true;
        } else if (in_string and c == string_char and (i == 0 or property_map[i - 1] != '\\')) {
            in_string = false;
        } else if (!in_string) {
            if (c == '{' or c == '[' or c == '(') depth += 1;
            if (c == '}' or c == ']' or c == ')') {
                if (depth > 0) depth -= 1;
            }
            if (c == ',' and depth == 1) {
                count += 1;
            }
            if (c == ':' and depth == 1) {
                has_content = true;
            }
        }
    }

    // If we have content but no commas, that's one property
    if (has_content and count == 0) return 1;
    // Otherwise, count + 1 for the last property
    return if (count > 0) count + 1 else 0;
}

/// Get the length of the current line (from the last newline to end).
fn getLineLength(items: []const u8) usize {
    var len: usize = 0;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        if (items[i] == '\n') break;
        len += 1;
    }
    return len;
}

/// Fold a property map onto multiple lines.
fn foldPropertyMap(allocator: Allocator, result: *std.ArrayList(u8), property_map: []const u8, base_indent: usize, options: FormattingOptions) !void {
    const indent_str = "    "; // 4 spaces per level
    const prop_indent = options.indent_size;

    // Opening brace
    try result.append(allocator, '{');
    try result.append(allocator, '\n');

    // Add base indent + one level for properties
    for (0..base_indent) |_| {
        try result.append(allocator, ' ');
    }
    for (0..prop_indent) |_| {
        try result.append(allocator, ' ');
    }
    _ = indent_str;

    // Parse and add each property on its own line
    var in_string = false;
    var string_char: u8 = 0;
    var depth: usize = 0;
    var i: usize = 1; // Skip opening brace
    var prop_start: usize = 1;

    while (i < property_map.len) {
        const c = property_map[i];

        if (!in_string and (c == '\'' or c == '"')) {
            in_string = true;
            string_char = c;
        } else if (in_string and c == string_char and (i == 0 or property_map[i - 1] != '\\')) {
            in_string = false;
        } else if (!in_string) {
            if (c == '{' or c == '[' or c == '(') depth += 1;
            if (c == '}' or c == ']' or c == ')') {
                if (depth > 0) {
                    depth -= 1;
                } else {
                    // End of property map - add last property
                    const prop = std.mem.trim(u8, property_map[prop_start..i], " \t\n\r");
                    if (prop.len > 0) {
                        try result.appendSlice(allocator, prop);
                        try result.append(allocator, '\n');
                    }
                    // Add closing brace with base indent
                    for (0..base_indent) |_| {
                        try result.append(allocator, ' ');
                    }
                    try result.append(allocator, '}');
                    return;
                }
            }
            if (c == ',' and depth == 0) {
                // Property separator - add this property
                const prop = std.mem.trim(u8, property_map[prop_start..i], " \t\n\r");
                if (prop.len > 0) {
                    try result.appendSlice(allocator, prop);
                    try result.append(allocator, ',');
                    try result.append(allocator, '\n');
                    // Add indent for next property
                    for (0..base_indent) |_| {
                        try result.append(allocator, ' ');
                    }
                    for (0..prop_indent) |_| {
                        try result.append(allocator, ' ');
                    }
                }
                prop_start = i + 1;
            }
        }
        i += 1;
    }
}

/// Apply proper indentation to formatted GQL code.
/// Handles CASE/WHEN/ELSE/END, multi-line RETURN items, and subqueries.
fn applyIndentation(allocator: Allocator, text: []const u8, indent_size: u32) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, text.len * 2);
    errdefer result.deinit(allocator);

    const indent_str = "    "; // 4 spaces per level
    _ = indent_size; // Use fixed 4 spaces for now

    const base_indent: usize = 0;
    var case_depth: usize = 0;
    var brace_depth: usize = 0;
    var paren_depth: usize = 0;
    var in_return_list = false;
    var in_string = false;
    var string_char: u8 = 0;

    // Process line by line
    var line_start: usize = 0;
    var pos: usize = 0;

    while (pos <= text.len) {
        // Find end of current line
        const is_end = pos == text.len;
        const is_newline = !is_end and text[pos] == '\n';

        if (is_newline or is_end) {
            const line = text[line_start..pos];
            const trimmed = std.mem.trim(u8, line, " \t");

            // Skip empty lines
            if (trimmed.len == 0) {
                try result.append(allocator, '\n');
                line_start = pos + 1;
                pos += 1;
                continue;
            }

            // Check for keywords that affect indentation
            var upper_buf: [64]u8 = undefined;
            const check_len = @min(trimmed.len, 10);
            var first_word_end: usize = 0;
            for (trimmed[0..check_len], 0..) |c, idx| {
                if (!std.ascii.isAlphabetic(c) and c != '_') {
                    first_word_end = idx;
                    break;
                }
                upper_buf[idx] = std.ascii.toUpper(c);
                first_word_end = idx + 1;
            }
            const first_word = upper_buf[0..first_word_end];

            // Adjust indent before writing the line
            var this_line_indent = base_indent;

            // WHEN/ELSE get extra indent inside CASE
            if (case_depth > 0 and (std.mem.eql(u8, first_word, "WHEN") or std.mem.eql(u8, first_word, "ELSE"))) {
                this_line_indent = base_indent + 1;
            }

            // Continuation lines (lines starting with comma-separated items after RETURN)
            if (in_return_list and !isClauseKeyword(first_word) and trimmed.len > 0 and trimmed[0] != '-') {
                this_line_indent = base_indent + 1;
            }

            // Lines inside braces (subqueries)
            if (brace_depth > 0 and trimmed[0] != '}') {
                this_line_indent = base_indent + brace_depth;
            }

            // Write indentation
            for (0..this_line_indent) |_| {
                try result.appendSlice(allocator, indent_str);
            }

            // Write the line content
            try result.appendSlice(allocator, trimmed);
            try result.append(allocator, '\n');

            // Update state for next line
            var i: usize = 0;
            in_string = false;
            while (i < trimmed.len) {
                const c = trimmed[i];

                // Handle strings
                if (!in_string and (c == '\'' or c == '"')) {
                    in_string = true;
                    string_char = c;
                    i += 1;
                    continue;
                }
                if (in_string) {
                    if (c == string_char and (i == 0 or trimmed[i - 1] != '\\')) {
                        in_string = false;
                    }
                    i += 1;
                    continue;
                }

                // Track braces and parens
                if (c == '{') brace_depth += 1;
                if (c == '}' and brace_depth > 0) brace_depth -= 1;
                if (c == '(') paren_depth += 1;
                if (c == ')' and paren_depth > 0) paren_depth -= 1;

                // Check for CASE keyword
                if (i + 4 <= trimmed.len and std.ascii.eqlIgnoreCase(trimmed[i .. i + 4], "CASE")) {
                    if (i + 4 >= trimmed.len or !std.ascii.isAlphanumeric(trimmed[i + 4])) {
                        case_depth += 1;
                    }
                }

                // Check for END keyword
                if (i + 3 <= trimmed.len and std.ascii.eqlIgnoreCase(trimmed[i .. i + 3], "END")) {
                    if ((i == 0 or !std.ascii.isAlphanumeric(trimmed[i - 1])) and
                        (i + 3 >= trimmed.len or !std.ascii.isAlphanumeric(trimmed[i + 3])))
                    {
                        if (case_depth > 0) case_depth -= 1;
                    }
                }

                i += 1;
            }

            // Track RETURN clause for multi-line items
            if (std.mem.eql(u8, first_word, "RETURN") or std.mem.eql(u8, first_word, "WITH")) {
                const last_char = if (trimmed.len > 0) trimmed[trimmed.len - 1] else ' ';
                in_return_list = (last_char == ',');
            } else if (isClauseKeyword(first_word)) {
                in_return_list = false;
            } else if (in_return_list) {
                const last_char = if (trimmed.len > 0) trimmed[trimmed.len - 1] else ' ';
                in_return_list = (last_char == ',');
            }

            line_start = pos + 1;
        }

        if (is_end) break;
        pos += 1;
    }

    // Trim trailing newlines except for one
    while (result.items.len > 1 and
        result.items[result.items.len - 1] == '\n' and
        result.items[result.items.len - 2] == '\n')
    {
        _ = result.pop();
    }

    return try result.toOwnedSlice(allocator);
}

/// Suppress unused variable warning
fn suppressUnused(x: anytype) void {
    _ = x;
}

fn isClauseKeyword(word: []const u8) bool {
    // GQL clause-starting keywords (ISO/IEC 39075:2024)
    const clause_keywords = [_][]const u8{
        "MATCH",    "CREATE",    "INSERT", "DELETE",
        "RETURN",   "WHERE",     "WITH",   "SET",
        "ORDER",    "GROUP",     "HAVING", "LIMIT",
        "OFFSET",   "UNION",     "EXCEPT", "CALL",
        "USE",      "DROP",      "SHOW",   "DETACH",
        "OPTIONAL", "INTERSECT", "LET",    "FOR",
        "FILTER",   "NEXT",
    };
    for (clause_keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

/// Basic formatting: keyword casing and newlines before clause keywords.
fn formatBasic(allocator: Allocator, text: []const u8) !?[]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, text.len);
    errdefer result.deinit(allocator);

    // Keywords that should start on a new line (clause starters)
    const line_start_keywords = std.StaticStringMap(void).initComptime(.{
        .{ "MATCH", {} },
        .{ "CREATE", {} },
        .{ "MERGE", {} },
        .{ "DELETE", {} },
        .{ "INSERT", {} },
        .{ "RETURN", {} },
        .{ "WHERE", {} },
        .{ "WITH", {} },
        .{ "SET", {} },
        .{ "REMOVE", {} },
        .{ "ORDER", {} },
        .{ "GROUP", {} },
        .{ "HAVING", {} },
        .{ "LIMIT", {} },
        .{ "SKIP", {} },
        .{ "OFFSET", {} },
        .{ "UNION", {} },
        .{ "INTERSECT", {} },
        .{ "EXCEPT", {} },
        .{ "OPTIONAL", {} },
        .{ "CALL", {} },
        .{ "UNWIND", {} },
        .{ "USE", {} },
        .{ "DROP", {} },
        .{ "SHOW", {} },
        .{ "EXPLAIN", {} },
        .{ "PROFILE", {} },
        .{ "DETACH", {} },
    });

    var i: usize = 0;
    var line_start = true;
    var in_string = false;
    var string_char: u8 = 0;
    var last_was_newline = true;
    var last_was_space = false;
    var last_was_comment = false; // Track if previous line was a comment (for comment groups)

    while (i < text.len) {
        const c = text[i];

        // Handle string literals
        if (!in_string and (c == '\'' or c == '"')) {
            in_string = true;
            string_char = c;
            try result.append(allocator, c);
            last_was_space = false;
            last_was_newline = false;
            i += 1;
            continue;
        }

        if (in_string) {
            try result.append(allocator, c);
            if (c == string_char and (i == 0 or text[i - 1] != '\\')) {
                in_string = false;
            }
            if (c == '\n') {
                last_was_newline = true;
                last_was_space = false;
            } else {
                last_was_newline = false;
                last_was_space = false;
            }
            i += 1;
            continue;
        }

        // Handle comments
        if (i + 1 < text.len) {
            // Single-line comment
            if ((c == '-' and text[i + 1] == '-') or (c == '/' and text[i + 1] == '/')) {
                // Add blank line before comment if:
                // - Not at start of file
                // - Previous line was NOT a comment (keep comment groups together)
                // - Not already preceded by blank line
                if (result.items.len > 0 and !last_was_comment) {
                    if (!last_was_newline) {
                        // Trim trailing space before adding newlines
                        while (result.items.len > 0 and result.items[result.items.len - 1] == ' ') {
                            _ = result.pop();
                        }
                        try result.append(allocator, '\n');
                        try result.append(allocator, '\n');
                    } else {
                        // Check if we already have a blank line (double newline)
                        const has_blank_line = result.items.len >= 2 and
                            result.items[result.items.len - 1] == '\n' and
                            result.items[result.items.len - 2] == '\n';
                        if (!has_blank_line) {
                            try result.append(allocator, '\n');
                        }
                    }
                }
                // Copy until newline
                while (i < text.len and text[i] != '\n') {
                    try result.append(allocator, text[i]);
                    i += 1;
                }
                if (i < text.len) {
                    try result.append(allocator, '\n');
                    i += 1;
                    last_was_newline = true;
                    last_was_space = false;
                    last_was_comment = true; // Mark that we just processed a comment
                    line_start = true;
                }
                continue;
            }
            // Multi-line comment
            if (c == '/' and text[i + 1] == '*') {
                // Add blank line before comment if:
                // - Not at start of file
                // - Previous line was NOT a comment (keep comment groups together)
                // - Not already preceded by blank line
                if (result.items.len > 0 and !last_was_comment) {
                    if (!last_was_newline) {
                        while (result.items.len > 0 and result.items[result.items.len - 1] == ' ') {
                            _ = result.pop();
                        }
                        try result.append(allocator, '\n');
                        try result.append(allocator, '\n');
                    } else {
                        const has_blank_line = result.items.len >= 2 and
                            result.items[result.items.len - 1] == '\n' and
                            result.items[result.items.len - 2] == '\n';
                        if (!has_blank_line) {
                            try result.append(allocator, '\n');
                        }
                    }
                }
                try result.append(allocator, '/');
                try result.append(allocator, '*');
                i += 2;
                while (i + 1 < text.len) {
                    if (text[i] == '*' and text[i + 1] == '/') {
                        try result.append(allocator, '*');
                        try result.append(allocator, '/');
                        i += 2;
                        break;
                    }
                    try result.append(allocator, text[i]);
                    i += 1;
                }
                last_was_space = false;
                last_was_newline = false;
                last_was_comment = true; // Mark that we just processed a comment
                continue;
            }
        }

        // Handle newlines
        if (c == '\n') {
            // Avoid multiple consecutive blank lines
            if (!last_was_newline or result.items.len == 0) {
                try result.append(allocator, '\n');
            }
            last_was_newline = true;
            last_was_space = false;
            line_start = true;
            i += 1;
            continue;
        }

        // Handle whitespace
        if (std.ascii.isWhitespace(c)) {
            if (!last_was_space and !last_was_newline and result.items.len > 0) {
                try result.append(allocator, ' ');
                last_was_space = true;
            }
            i += 1;
            continue;
        }

        // Handle identifiers and keywords
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = i;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) {
                i += 1;
            }
            const word = text[start..i];

            // Check if it's a keyword
            var upper_buf: [64]u8 = undefined;
            const upper_len = @min(word.len, 64);
            for (word[0..upper_len], 0..) |ch, j| {
                upper_buf[j] = std.ascii.toUpper(ch);
            }
            const upper_word = upper_buf[0..upper_len];

            // Check if this word is a known function (case-sensitive check)
            const is_known_function = for (GQL_FUNCTIONS) |func| {
                if (std.mem.eql(u8, word, func)) break true;
            } else false;

            // Check if it's a keyword only if it's NOT a known function name
            // This ensures that functions like count(), all(), any() don't get uppercased
            // even when they match keyword patterns like "ALL" for "UNION ALL"
            const is_keyword = if (is_known_function)
                false
            else for (GQL_KEYWORDS) |kw| {
                if (std.mem.eql(u8, upper_word, kw)) break true;
            } else false;

            // Check if this is a clause-starting keyword that needs a newline before it
            var needs_newline = line_start_keywords.get(upper_word) != null;

            // Suppress newline if this is part of a compound keyword (e.g., OPTIONAL MATCH, DETACH DELETE)
            // Look back in result buffer to see if previous word was a compound prefix
            if (needs_newline and result.items.len > 0) {
                // Check for "OPTIONAL " before MATCH
                if (std.mem.eql(u8, upper_word, "MATCH") and result.items.len >= 9) {
                    const suffix = result.items[result.items.len - 9 ..];
                    if (std.mem.eql(u8, suffix, "OPTIONAL ")) {
                        needs_newline = false;
                    }
                }
                // Check for "DETACH " before DELETE
                if (std.mem.eql(u8, upper_word, "DELETE") and result.items.len >= 7) {
                    const suffix = result.items[result.items.len - 7 ..];
                    if (std.mem.eql(u8, suffix, "DETACH ")) {
                        needs_newline = false;
                    }
                }
            }

            if (needs_newline and !last_was_newline and result.items.len > 0) {
                // Trim trailing space before newline
                while (result.items.len > 0 and result.items[result.items.len - 1] == ' ') {
                    _ = result.pop();
                }
                try result.append(allocator, '\n');
                last_was_newline = true;
                last_was_space = false;
            }

            if (is_keyword) {
                // Output uppercase keyword
                try result.appendSlice(allocator, upper_word);
            } else {
                // Preserve original case for non-keywords
                try result.appendSlice(allocator, word);
            }

            last_was_space = false;
            last_was_newline = false;
            last_was_comment = false; // Reset comment flag when processing non-comment content
            line_start = false;
            continue;
        }

        // Handle other characters (punctuation, operators, etc.)
        try result.append(allocator, c);
        last_was_space = false;
        last_was_newline = (c == '\n');

        // Add blank line after semicolon to separate statements
        if (c == ';') {
            try result.append(allocator, '\n');
            // Skip whitespace and newlines to find next meaningful content
            var peek = i + 1;
            while (peek < text.len and (text[peek] == ' ' or text[peek] == '\t' or text[peek] == '\r' or text[peek] == '\n')) {
                peek += 1;
            }
            // Add blank line unless next thing is a comment (comments provide their own separation)
            // or we've reached end of file
            if (peek < text.len and
                !(peek + 1 < text.len and text[peek] == '-' and text[peek + 1] == '-') and
                !(peek + 1 < text.len and text[peek] == '/' and text[peek + 1] == '/'))
            {
                try result.append(allocator, '\n');
            }
            last_was_newline = true;
            line_start = true;
        }

        i += 1;
    }

    // Trim trailing whitespace
    while (result.items.len > 0 and std.ascii.isWhitespace(result.items[result.items.len - 1])) {
        _ = result.pop();
    }

    // Ensure file ends with newline
    if (result.items.len > 0) {
        try result.append(allocator, '\n');
    }

    return try result.toOwnedSlice(allocator);
}

// NOTE: Old documentation functions removed in favor of metadata-based formatXXXHover functions
// See formatKeywordHover, formatFunctionHover, formatTypeHover, formatProcedureHover above

// ============================================================================
// Unit Tests for Formatting
// ============================================================================

test "provideFormatting - keyword uppercasing" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "match (n) return n", 1);
    defer doc.deinit();

    const result = try provideFormatting(allocator, doc);
    defer if (result) |r| allocator.free(r);

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("MATCH (n)\nRETURN n\n", result.?);
}

test "provideFormatting - preserves string literals" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "match (n {name: 'match me'}) return n", 1);
    defer doc.deinit();

    const result = try provideFormatting(allocator, doc);
    defer if (result) |r| allocator.free(r);

    try std.testing.expect(result != null);
    // Keywords should be uppercased but 'match me' inside string should be preserved
    try std.testing.expect(std.mem.indexOf(u8, result.?, "'match me'") != null);
}

test "provideFormatting - preserves comments" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "-- comment here\nmatch (n) return n", 1);
    defer doc.deinit();

    const result = try provideFormatting(allocator, doc);
    defer if (result) |r| allocator.free(r);

    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "-- comment here") != null);
}

test "provideFormatting - multiline comment preserved" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "/* block\ncomment */ match (n) return n", 1);
    defer doc.deinit();

    const result = try provideFormatting(allocator, doc);
    defer if (result) |r| allocator.free(r);

    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "/* block") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "comment */") != null);
}

test "provideFormatting - newlines before clause keywords" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "match (n) where n.x > 1 return n", 1);
    defer doc.deinit();

    const result = try provideFormatting(allocator, doc);
    defer if (result) |r| allocator.free(r);

    try std.testing.expect(result != null);
    // WHERE and RETURN should start on new lines
    try std.testing.expect(std.mem.indexOf(u8, result.?, "\nWHERE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "\nRETURN") != null);
}

test "provideFormatting - empty document" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "", 1);
    defer doc.deinit();

    const result = try provideFormatting(allocator, doc);
    try std.testing.expect(result == null);
}

test "provideFormatting - variable names preserved" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "match (myNode:Person) return myNode", 1);
    defer doc.deinit();

    const result = try provideFormatting(allocator, doc);
    defer if (result) |r| allocator.free(r);

    try std.testing.expect(result != null);
    // Variable names should preserve original case
    try std.testing.expect(std.mem.indexOf(u8, result.?, "myNode") != null);
}
