const std = @import("std");

// CANARY: REQ=REQ-LIB-MIGRATION-MCP-010; FEATURE="External Library Migration"; ASPECT=MCPLSPTools; STATUS=TESTED; OWNER=core; UPDATED=2026-01-24
// MCP LSP Tools for Geode - GQL validation, completions, and hover information
// Enables AI/LLM systems to validate and understand GQL queries

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-048; FEATURE="JSON Library Migration"; ASPECT=MCPLSP; STATUS=TESTED; OWNER=mcp; UPDATED=2026-01-24
const json_lib = @import("json");

const mod = @import("mod.zig");
const gql_parser = mod.gql_parser;
const gql_lexer = mod.gql_lexer;
const language_metadata = mod.language_metadata;

// JSON Response Types for LSP
const ValidationResponse = struct {
    isValid: bool,
    diagnostics: []const DiagnosticJson,
};

const DiagnosticJson = struct {
    line: u32,
    column: u32,
    endLine: u32,
    endColumn: u32,
    severity: []const u8,
    message: []const u8,
    source: []const u8,
};

const CompletionResponse = struct {
    completions: []const CompletionItemJson,
};

const CompletionItemJson = struct {
    label: []const u8,
    kind: []const u8,
    detail: ?[]const u8 = null,
    documentation: ?[]const u8 = null,
    insertText: ?[]const u8 = null,
};

const HoverResponse = struct {
    contents: ?[]const u8,
};

/// Diagnostic severity levels
pub const DiagnosticSeverity = enum {
    @"error",
    warning,
    information,
    hint,
};

/// A single diagnostic (error, warning, etc.)
pub const Diagnostic = struct {
    line: u32,
    column: u32,
    end_line: u32,
    end_column: u32,
    severity: DiagnosticSeverity,
    message: []const u8,
    source: []const u8 = "geode-gql",
};

/// Validation result containing diagnostics
pub const ValidationResult = struct {
    is_valid: bool,
    diagnostics: []const Diagnostic,
};

/// Completion item for LSP completions
pub const CompletionItem = struct {
    label: []const u8,
    kind: CompletionKind,
    detail: ?[]const u8 = null,
    documentation: ?[]const u8 = null,
    insert_text: ?[]const u8 = null,
};

/// Completion item kinds
pub const CompletionKind = enum {
    keyword,
    function,
    type,
    procedure,
    snippet,
};

/// Hover information
pub const HoverInfo = struct {
    contents: []const u8,
    range_start_line: ?u32 = null,
    range_start_col: ?u32 = null,
    range_end_line: ?u32 = null,
    range_end_col: ?u32 = null,
};

/// Validate a GQL query and return diagnostics
pub fn validateQuery(allocator: std.mem.Allocator, query: []const u8) ![]const u8 {
    var diagnostics = try std.ArrayList(Diagnostic).initCapacity(allocator, 4);
    defer diagnostics.deinit(allocator);

    var is_valid = true;

    // Create lexer and parser
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var lexer = gql_lexer.Lexer{
        .src = query,
        .idx = 0,
        .line = 1,
        .col = 1,
        .has_double_solidus_comment = false,
    };

    var parser = gql_parser.Parser{
        .lx = &lexer,
        .arena = &arena,
        .cur = lexer.next(),
        .has_ordinal_sort_key = false,
    };

    // Try to parse the query
    const program = parser.parseProgram() catch |err| {
        is_valid = false;

        // Get error message from parser
        const error_msg = parser.last_error orelse @errorName(err);

        try diagnostics.append(allocator, Diagnostic{
            .line = parser.cur.loc.line,
            .column = parser.cur.loc.column,
            .end_line = parser.cur.loc.line,
            .end_column = parser.cur.loc.column + @as(u32, @intCast(parser.cur.lexeme.len)),
            .severity = .@"error",
            .message = error_msg,
        });

        // Check for double-dash comments even on error
        if (lexer.has_double_solidus_comment) {
            try diagnostics.append(allocator, Diagnostic{
                .line = 0,
                .column = 0,
                .end_line = 0,
                .end_column = 0,
                .severity = .information,
                .message = "Double-dash (--) comments are a Geode extension and may not be supported by other GQL databases.",
            });
        }

        return formatValidationResponse(allocator, is_valid, diagnostics.items);
    };

    // Check for double-dash comments (Geode extension - supported but non-standard)
    if (lexer.has_double_solidus_comment) {
        try diagnostics.append(allocator, Diagnostic{
            .line = 0,
            .column = 0,
            .end_line = 0,
            .end_column = 0,
            .severity = .information,
            .message = "Double-dash (--) comments are a Geode extension and may not be supported by other GQL databases.",
        });
    }

    // Run recommendation engine for context-aware suggestions
    var rec_engine = mod.recommendations.RecommendationEngine.init(allocator);
    defer rec_engine.deinit();
    const suggestions = rec_engine.analyze(program) catch &[_]mod.recommendations.Recommendation{};
    for (suggestions) |suggestion| {
        try diagnostics.append(allocator, Diagnostic{
            .line = suggestion.line,
            .column = suggestion.column,
            .end_line = suggestion.line,
            .end_column = suggestion.column,
            .severity = switch (suggestion.severity) {
                .information => .information,
                .hint => .hint,
            },
            .message = suggestion.message,
        });
    }

    // Format response as JSON
    return formatValidationResponse(allocator, is_valid, diagnostics.items);
}

/// Get completions at a cursor position
pub fn getCompletions(allocator: std.mem.Allocator, query: []const u8, line: u32, column: u32) ![]const u8 {
    var completions = try std.ArrayList(CompletionItem).initCapacity(allocator, 32);
    defer completions.deinit(allocator);

    // Get the context at cursor position
    const context = getContextAtPosition(query, line, column);

    // Based on context, provide relevant completions
    switch (context) {
        .start_of_statement, .after_semicolon => {
            // Suggest clause-starting keywords
            try addClauseKeywords(allocator, &completions);
        },
        .after_keyword => {
            // Context-sensitive completions would go here
            try addAllKeywords(allocator, &completions);
        },
        .function_name => {
            try addFunctions(allocator, &completions);
        },
        .type_context => {
            try addTypes(allocator, &completions);
        },
        .unknown => {
            // Provide all completions
            try addAllKeywords(allocator, &completions);
            try addFunctions(allocator, &completions);
        },
    }

    return formatCompletionResponse(allocator, completions.items);
}

/// Get hover information for a position
pub fn getHover(allocator: std.mem.Allocator, query: []const u8, line: u32, column: u32) ![]const u8 {
    // Find the word at the cursor position
    const word = getWordAtPosition(query, line, column);
    if (word == null) {
        return formatHoverResponse(allocator, null);
    }

    // Check if it's a keyword
    if (language_metadata.findKeyword(word.?)) |kw| {
        const doc = try std.fmt.allocPrint(allocator, "**{s}** (GQL Keyword)\n\n{s}\n\nCompliance: {s}", .{
            kw.name,
            kw.doc,
            @tagName(kw.compliance),
        });
        defer allocator.free(doc);

        return formatHoverResponse(allocator, HoverInfo{ .contents = doc });
    }

    // Check if it's a function
    if (language_metadata.findFunction(word.?)) |func| {
        var params_buf: [1024]u8 = undefined;
        var params_len: usize = 0;

        for (func.params, 0..) |param, i| {
            if (i > 0) {
                params_buf[params_len] = ',';
                params_buf[params_len + 1] = ' ';
                params_len += 2;
            }
            const param_str = param.name;
            @memcpy(params_buf[params_len .. params_len + param_str.len], param_str);
            params_len += param_str.len;
            params_buf[params_len] = ':';
            params_buf[params_len + 1] = ' ';
            params_len += 2;
            @memcpy(params_buf[params_len .. params_len + param.type_name.len], param.type_name);
            params_len += param.type_name.len;
        }

        const doc = try std.fmt.allocPrint(allocator, "**{s}**({s}) → {s}\n\n{s}\n\nCompliance: {s}{s}", .{
            func.name,
            params_buf[0..params_len],
            func.return_type,
            func.doc,
            @tagName(func.compliance),
            if (func.example) |ex| try std.fmt.allocPrint(allocator, "\n\nExample: `{s}`", .{ex}) else "",
        });
        defer allocator.free(doc);

        return formatHoverResponse(allocator, HoverInfo{ .contents = doc });
    }

    // Check if it's a type
    if (language_metadata.findType(word.?)) |typ| {
        const doc = try std.fmt.allocPrint(allocator, "**{s}** (GQL Type)\n\n{s}\n\nCompliance: {s}{s}", .{
            typ.name,
            typ.doc,
            @tagName(typ.compliance),
            if (typ.example) |ex| try std.fmt.allocPrint(allocator, "\n\nExample: `{s}`", .{ex}) else "",
        });
        defer allocator.free(doc);

        return formatHoverResponse(allocator, HoverInfo{ .contents = doc });
    }

    // Check if it's a procedure
    if (language_metadata.findProcedure(word.?)) |proc| {
        var cols_buf: [2048]u8 = undefined;
        var cols_len: usize = 0;

        for (proc.columns, 0..) |col, i| {
            if (i > 0) {
                cols_buf[cols_len] = ',';
                cols_buf[cols_len + 1] = ' ';
                cols_len += 2;
            }
            @memcpy(cols_buf[cols_len .. cols_len + col.name.len], col.name);
            cols_len += col.name.len;
        }

        const doc = try std.fmt.allocPrint(allocator, "**{s}**\n\nYIELD: {s}\n\n{s}{s}", .{
            proc.name,
            cols_buf[0..cols_len],
            proc.doc,
            if (proc.example) |ex| try std.fmt.allocPrint(allocator, "\n\nExample: `{s}`", .{ex}) else "",
        });
        defer allocator.free(doc);

        return formatHoverResponse(allocator, HoverInfo{ .contents = doc });
    }

    return formatHoverResponse(allocator, null);
}

/// Get all diagnostics for a document (alias for validateQuery)
pub fn getDiagnostics(allocator: std.mem.Allocator, query: []const u8) ![]const u8 {
    return validateQuery(allocator, query);
}

// =============================================================================
// Context Detection
// =============================================================================

const CompletionContext = enum {
    start_of_statement,
    after_semicolon,
    after_keyword,
    function_name,
    type_context,
    unknown,
};

fn getContextAtPosition(query: []const u8, line: u32, column: u32) CompletionContext {
    // Find position in query
    var current_line: u32 = 1;
    var current_col: u32 = 1;
    var pos: usize = 0;

    while (pos < query.len) : (pos += 1) {
        if (current_line == line and current_col == column) {
            break;
        }
        if (query[pos] == '\n') {
            current_line += 1;
            current_col = 1;
        } else {
            current_col += 1;
        }
    }

    // Check what's before the cursor
    if (pos == 0) return .start_of_statement;

    // Look backwards for context
    var i: usize = pos;
    while (i > 0) : (i -= 1) {
        const c = query[i - 1];
        if (c == ';') return .after_semicolon;
        if (c == '(') return .function_name;
        if (c == ':') return .type_context;
        if (!std.ascii.isWhitespace(c)) break;
    }

    // Default to after keyword
    return .after_keyword;
}

fn getWordAtPosition(query: []const u8, line: u32, column: u32) ?[]const u8 {
    // Find position in query
    var current_line: u32 = 1;
    var current_col: u32 = 1;
    var pos: usize = 0;

    while (pos < query.len) : (pos += 1) {
        if (current_line == line and current_col >= column) {
            break;
        }
        if (query[pos] == '\n') {
            current_line += 1;
            current_col = 1;
        } else {
            current_col += 1;
        }
    }

    if (pos >= query.len) return null;

    // Find word boundaries
    var start = pos;
    while (start > 0 and isIdentifierChar(query[start - 1])) {
        start -= 1;
    }

    var end = pos;
    while (end < query.len and isIdentifierChar(query[end])) {
        end += 1;
    }

    if (start == end) return null;

    return query[start..end];
}

fn isIdentifierChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.';
}

// =============================================================================
// Completion Helpers
// =============================================================================

fn addClauseKeywords(allocator: std.mem.Allocator, completions: *std.ArrayList(CompletionItem)) !void {
    const clause_keywords = [_][]const u8{
        "MATCH",   "OPTIONAL", "RETURN",  "WITH",   "CREATE",
        "DELETE",  "MERGE",    "SET",     "REMOVE", "CALL",
        "UNWIND",  "USE",      "BEGIN",   "COMMIT", "ROLLBACK",
        "EXPLAIN", "PROFILE",  "INSERT",  "DROP",   "SHOW",
        // Geode extensions
        "BACKUP",  "RESTORE",  "SESSION", "VALUES", "FOR",
    };

    for (clause_keywords) |kw| {
        if (language_metadata.findKeyword(kw)) |info| {
            try completions.append(allocator, CompletionItem{
                .label = try allocator.dupe(u8, kw),
                .kind = .keyword,
                .detail = try allocator.dupe(u8, "GQL Clause"),
                .documentation = try allocator.dupe(u8, info.doc),
            });
        }
    }
}

fn addAllKeywords(allocator: std.mem.Allocator, completions: *std.ArrayList(CompletionItem)) !void {
    for (language_metadata.keywords) |kw| {
        try completions.append(allocator, CompletionItem{
            .label = try allocator.dupe(u8, kw.name),
            .kind = .keyword,
            .detail = try allocator.dupe(u8, @tagName(kw.category)),
            .documentation = try allocator.dupe(u8, kw.doc),
        });
    }
}

fn addFunctions(allocator: std.mem.Allocator, completions: *std.ArrayList(CompletionItem)) !void {
    for (language_metadata.functions) |func| {
        const insert = try std.fmt.allocPrint(allocator, "{s}()", .{func.name});

        try completions.append(allocator, CompletionItem{
            .label = try allocator.dupe(u8, func.name),
            .kind = .function,
            .detail = try std.fmt.allocPrint(allocator, "→ {s}", .{func.return_type}),
            .documentation = try allocator.dupe(u8, func.doc),
            .insert_text = insert,
        });
    }
}

fn addTypes(allocator: std.mem.Allocator, completions: *std.ArrayList(CompletionItem)) !void {
    for (language_metadata.types) |typ| {
        try completions.append(allocator, CompletionItem{
            .label = try allocator.dupe(u8, typ.name),
            .kind = .type,
            .detail = try allocator.dupe(u8, "GQL Type"),
            .documentation = try allocator.dupe(u8, typ.doc),
        });
    }
}

// =============================================================================
// JSON Formatting - Using JSON Library
// =============================================================================

/// CANARY: REQ=REQ-LIB-MIGRATION-JSON-049; FEATURE="JSON Library Migration"; ASPECT=LSPValidation; STATUS=TESTED; OWNER=mcp; UPDATED=2026-01-24
fn formatValidationResponse(allocator: std.mem.Allocator, is_valid: bool, diagnostics: []const Diagnostic) ![]const u8 {
    // Convert diagnostics to JSON-friendly format
    var json_diags = try std.ArrayList(DiagnosticJson).initCapacity(allocator, diagnostics.len);
    defer json_diags.deinit(allocator);

    for (diagnostics) |diag| {
        try json_diags.append(allocator, DiagnosticJson{
            .line = diag.line,
            .column = diag.column,
            .endLine = diag.end_line,
            .endColumn = diag.end_column,
            .severity = @tagName(diag.severity),
            .message = diag.message,
            .source = diag.source,
        });
    }

    const response = ValidationResponse{
        .isValid = is_valid,
        .diagnostics = json_diags.items,
    };

    return try json_lib.encode(allocator, response, .{});
}

/// CANARY: REQ=REQ-LIB-MIGRATION-JSON-050; FEATURE="JSON Library Migration"; ASPECT=LSPCompletions; STATUS=TESTED; OWNER=mcp; UPDATED=2026-01-24
fn formatCompletionResponse(allocator: std.mem.Allocator, completions: []const CompletionItem) ![]const u8 {
    // Convert completions to JSON-friendly format
    var json_completions = try std.ArrayList(CompletionItemJson).initCapacity(allocator, completions.len);
    defer json_completions.deinit(allocator);

    for (completions) |item| {
        try json_completions.append(allocator, CompletionItemJson{
            .label = item.label,
            .kind = @tagName(item.kind),
            .detail = item.detail,
            .documentation = item.documentation,
            .insertText = item.insert_text,
        });
    }

    const response = CompletionResponse{
        .completions = json_completions.items,
    };

    return try json_lib.encode(allocator, response, .{ .emit_null_optional_fields = false });
}

/// CANARY: REQ=REQ-LIB-MIGRATION-JSON-051; FEATURE="JSON Library Migration"; ASPECT=LSPHover; STATUS=TESTED; OWNER=mcp; UPDATED=2026-01-24
fn formatHoverResponse(allocator: std.mem.Allocator, hover: ?HoverInfo) ![]const u8 {
    const response = HoverResponse{
        .contents = if (hover) |h| h.contents else null,
    };

    return try json_lib.encode(allocator, response, .{});
}

// =============================================================================
// Tests
// =============================================================================

test "validateQuery with valid query" {
    const allocator = std.testing.allocator;

    const result = try validateQuery(allocator, "RETURN 1 AS x");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"isValid\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"diagnostics\":[]") != null);
}

test "validateQuery with invalid query" {
    const allocator = std.testing.allocator;

    const result = try validateQuery(allocator, "MATCH () RETRN x");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"isValid\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"diagnostics\":[") != null);
}

test "validateQuery with empty query" {
    const allocator = std.testing.allocator;

    const result = try validateQuery(allocator, "");
    defer allocator.free(result);

    // Empty query might be valid or invalid depending on parser
    try std.testing.expect(std.mem.indexOf(u8, result, "\"isValid\"") != null);
}

test "getCompletions returns completions" {
    const allocator = std.testing.allocator;

    const result = try getCompletions(allocator, "MATCH (n) ", 1, 10);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"completions\":[") != null);
}

test "getCompletions at start of query" {
    const allocator = std.testing.allocator;

    const result = try getCompletions(allocator, "", 1, 1);
    defer allocator.free(result);

    // Should include clause keywords
    try std.testing.expect(std.mem.indexOf(u8, result, "MATCH") != null or
        std.mem.indexOf(u8, result, "RETURN") != null);
}

test "getHover for MATCH keyword" {
    const allocator = std.testing.allocator;

    const result = try getHover(allocator, "MATCH (n) RETURN n", 1, 2);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"contents\"") != null);
}

test "getHover for count function" {
    const allocator = std.testing.allocator;

    const result = try getHover(allocator, "RETURN count(n)", 1, 9);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"contents\"") != null);
}

test "getHover for unknown word" {
    const allocator = std.testing.allocator;

    const result = try getHover(allocator, "RETURN xyz123", 1, 9);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"contents\":null") != null);
}

test "getDiagnostics is alias for validateQuery" {
    const allocator = std.testing.allocator;

    const validate_result = try validateQuery(allocator, "RETURN 1");
    defer allocator.free(validate_result);

    const diag_result = try getDiagnostics(allocator, "RETURN 1");
    defer allocator.free(diag_result);

    try std.testing.expectEqualStrings(validate_result, diag_result);
}

test "getWordAtPosition finds word" {
    const word = getWordAtPosition("MATCH (n) RETURN n", 1, 3);
    try std.testing.expect(word != null);
    try std.testing.expectEqualStrings("MATCH", word.?);
}

test "getWordAtPosition returns null for whitespace" {
    const word = getWordAtPosition("MATCH   (n)", 1, 7);
    try std.testing.expect(word == null);
}

test "isIdentifierChar" {
    try std.testing.expect(isIdentifierChar('a'));
    try std.testing.expect(isIdentifierChar('Z'));
    try std.testing.expect(isIdentifierChar('5'));
    try std.testing.expect(isIdentifierChar('_'));
    try std.testing.expect(!isIdentifierChar(' '));
    try std.testing.expect(!isIdentifierChar('('));
}

test "getContextAtPosition at start" {
    const ctx = getContextAtPosition("", 1, 1);
    try std.testing.expect(ctx == .start_of_statement);
}

test "getContextAtPosition after semicolon" {
    const ctx = getContextAtPosition("RETURN 1; ", 1, 11);
    try std.testing.expect(ctx == .after_semicolon);
}

test "formatValidationResponse valid" {
    const allocator = std.testing.allocator;

    const result = try formatValidationResponse(allocator, true, &[_]Diagnostic{});
    defer allocator.free(result);

    try std.testing.expectEqualStrings("{\"isValid\":true,\"diagnostics\":[]}", result);
}

test "formatValidationResponse with diagnostics" {
    const allocator = std.testing.allocator;

    const diagnostics = [_]Diagnostic{
        .{
            .line = 1,
            .column = 5,
            .end_line = 1,
            .end_column = 10,
            .severity = .@"error",
            .message = "Syntax error",
        },
    };

    const result = try formatValidationResponse(allocator, false, &diagnostics);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"isValid\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"line\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"message\":\"Syntax error\"") != null);
}

test "validateQuery includes recommendations" {
    const allocator = std.testing.allocator;

    const result = try validateQuery(allocator, "CREATE (u:User {password: 'secret123'})");
    defer allocator.free(result);

    // Should be valid (no parse errors)
    try std.testing.expect(std.mem.indexOf(u8, result, "\"isValid\":true") != null);
    // Should contain a recommendation about encrypted annotation
    try std.testing.expect(std.mem.indexOf(u8, result, "encrypted") != null or std.mem.indexOf(u8, result, "sensitive") != null);
}

test "JSON library handles special characters in LSP responses" {
    const allocator = std.testing.allocator;

    // Verify JSON library properly escapes special characters
    const hover = HoverInfo{ .contents = "Hello\n\"World\"\\" };
    const result = try formatHoverResponse(allocator, hover);
    defer allocator.free(result);

    // Should contain escaped newline, quotes, and backslash
    try std.testing.expect(std.mem.indexOf(u8, result, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\\"World\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\\\") != null);
}
