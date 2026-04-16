const std = @import("std");

// CANARY: REQ=REQ-REPL-SYNTAX-001; FEATURE="REPL Syntax Highlighting"; ASPECT=Implementation; STATUS=TESTED; TEST=test_syntax_highlighting; OWNER=repl; UPDATED=2025-11-17

/// ANSI color codes for syntax highlighting
pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";

    // Foreground colors
    pub const black = "\x1b[30m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const white = "\x1b[37m";

    // Bright foreground colors
    pub const bright_black = "\x1b[90m";
    pub const bright_red = "\x1b[91m";
    pub const bright_green = "\x1b[92m";
    pub const bright_yellow = "\x1b[93m";
    pub const bright_blue = "\x1b[94m";
    pub const bright_magenta = "\x1b[95m";
    pub const bright_cyan = "\x1b[96m";
    pub const bright_white = "\x1b[97m";
};

/// Token types for syntax highlighting
pub const TokenType = enum {
    keyword, // GQL keywords (MATCH, RETURN, WHERE, etc.)
    operator, // Operators (=, <, >, <=, >=, etc.)
    string, // String literals
    number, // Numeric literals
    identifier, // Variable names, labels
    comment, // Comments
    parenthesis, // (), {}, []
    meta_command, // \ commands
    whitespace, // Whitespace
    unknown, // Unknown tokens
};

/// GQL keywords for highlighting
const gql_keywords = [_][]const u8{
    "MATCH",   "RETURN",   "WHERE",     "CREATE",        "DELETE",    "SET",     "REMOVE",
    "WITH",    "UNWIND",   "MERGE",     "CALL",          "UNION",     "ORDER",   "BY",
    "LIMIT",   "SKIP",     "DISTINCT",  "AS",            "AND",       "OR",      "NOT",
    "XOR",     "IN",       "STARTS",    "ENDS",          "CONTAINS",  "IS",      "NULL",
    "TRUE",    "FALSE",    "CASE",      "WHEN",          "THEN",      "ELSE",    "END",
    "FOREACH", "OPTIONAL", "DETACH",    "ON",            "USING",     "INDEX",   "CONSTRAINT",
    "ASSERT",  "EXISTS",   "UNIQUE",    "DROP",          "SHOW",      "ALL",     "COUNT",
    "SUM",     "AVG",      "MIN",       "MAX",           "COLLECT",   "HEAD",    "TAIL",
    "KEYS",    "LABELS",   "NODES",     "RELATIONSHIPS", "TYPE",      "ID",      "PROPERTIES",
    "LENGTH",  "SIZE",     "REVERSE",   "SUBSTRING",     "REPLACE",   "SPLIT",   "TRIM",
    "LTRIM",   "RTRIM",    "TOLOWER",   "TOUPPER",       "TOINTEGER", "TOFLOAT", "TOBOOLEAN",
    "ASC",     "DESC",     "ASCENDING", "DESCENDING",
};

/// Check if a word is a GQL keyword
fn isKeyword(word: []const u8) bool {
    for (gql_keywords) |keyword| {
        if (std.ascii.eqlIgnoreCase(word, keyword)) {
            return true;
        }
    }
    return false;
}

/// Check if a character is an operator
fn isOperatorChar(c: u8) bool {
    return switch (c) {
        '=', '<', '>', '!', '+', '-', '*', '/', '%', '^', '|', '&', '~' => true,
        else => false,
    };
}

/// Highlight GQL syntax with ANSI colors
pub fn highlight(allocator: std.mem.Allocator, input: []const u8, use_colors: bool) ![]u8 {
    if (!use_colors) {
        return allocator.dupe(u8, input);
    }

    const alloc = allocator;
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(alloc);

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];

        // Meta commands (starting with backslash or forward slash at position 0)
        // Note: check for // comment before treating / as meta-command
        if (c == '\\' or (c == '/' and i == 0 and (i + 1 >= input.len or input[i + 1] != '/'))) {
            try result.appendSlice(alloc, Color.bright_magenta);
            while (i < input.len and !std.ascii.isWhitespace(input[i])) : (i += 1) {
                try result.append(alloc, input[i]);
            }
            try result.appendSlice(alloc, Color.reset);
            continue;
        }

        // Comments (-- or //)
        if (i + 1 < input.len and ((c == '-' and input[i + 1] == '-') or (c == '/' and input[i + 1] == '/'))) {
            try result.appendSlice(alloc, Color.dim);
            try result.appendSlice(alloc, Color.bright_black);
            while (i < input.len and input[i] != '\n') : (i += 1) {
                try result.append(alloc, input[i]);
            }
            try result.appendSlice(alloc, Color.reset);
            continue;
        }

        // String literals (single or double quoted)
        if (c == '\'' or c == '"') {
            const quote = c;
            try result.appendSlice(alloc, Color.green);
            try result.append(alloc, c);
            i += 1;
            while (i < input.len) : (i += 1) {
                const ch = input[i];
                try result.append(alloc, ch);
                if (ch == quote) {
                    i += 1;
                    break;
                }
                if (ch == '\\' and i + 1 < input.len) {
                    i += 1;
                    try result.append(alloc, input[i]);
                }
            }
            try result.appendSlice(alloc, Color.reset);
            continue;
        }

        // Numbers
        if (std.ascii.isDigit(c)) {
            try result.appendSlice(alloc, Color.cyan);
            while (i < input.len and (std.ascii.isDigit(input[i]) or input[i] == '.')) : (i += 1) {
                try result.append(alloc, input[i]);
            }
            try result.appendSlice(alloc, Color.reset);
            continue;
        }

        // Identifiers and keywords
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = i;
            while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '_')) : (i += 1) {}
            const word = input[start..i];

            if (isKeyword(word)) {
                try result.appendSlice(alloc, Color.bold);
                try result.appendSlice(alloc, Color.blue);
                try result.appendSlice(alloc, word);
                try result.appendSlice(alloc, Color.reset);
            } else {
                // Regular identifier
                try result.appendSlice(alloc, Color.white);
                try result.appendSlice(alloc, word);
                try result.appendSlice(alloc, Color.reset);
            }
            continue;
        }

        // Operators
        if (isOperatorChar(c)) {
            try result.appendSlice(alloc, Color.yellow);
            while (i < input.len and isOperatorChar(input[i])) : (i += 1) {
                try result.append(alloc, input[i]);
            }
            try result.appendSlice(alloc, Color.reset);
            continue;
        }

        // Parentheses and brackets
        if (c == '(' or c == ')' or c == '{' or c == '}' or c == '[' or c == ']') {
            try result.appendSlice(alloc, Color.bright_yellow);
            try result.append(alloc, c);
            try result.appendSlice(alloc, Color.reset);
            i += 1;
            continue;
        }

        // Special characters (semicolon, comma, colon, dot)
        if (c == ';' or c == ',' or c == ':' or c == '.') {
            try result.appendSlice(alloc, Color.bright_white);
            try result.append(alloc, c);
            try result.appendSlice(alloc, Color.reset);
            i += 1;
            continue;
        }

        // Default: just append the character
        try result.append(alloc, c);
        i += 1;
    }

    return result.toOwnedSlice(alloc);
}

/// Highlight a single line of input as it's being typed
pub fn highlightInputLine(allocator: std.mem.Allocator, line: []const u8, use_colors: bool) ![]u8 {
    return highlight(allocator, line, use_colors);
}

/// Strip ANSI color codes from text
pub fn stripColors(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var in_escape = false;
    for (text) |c| {
        if (c == '\x1b') {
            in_escape = true;
        } else if (in_escape) {
            if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) {
                in_escape = false;
            }
        } else {
            try result.append(allocator, c);
        }
    }

    return result.toOwnedSlice(allocator);
}

test "isKeyword identifies GQL keywords" {
    try std.testing.expect(isKeyword("MATCH"));
    try std.testing.expect(isKeyword("match")); // case insensitive
    try std.testing.expect(isKeyword("RETURN"));
    try std.testing.expect(isKeyword("WHERE"));
    try std.testing.expect(!isKeyword("foo"));
    try std.testing.expect(!isKeyword("bar123"));
}

test "highlight simple GQL query" {
    const allocator = std.testing.allocator;
    const input = "MATCH (n) RETURN n";
    const highlighted = try highlight(allocator, input, true);
    defer allocator.free(highlighted);

    // Should contain color codes
    try std.testing.expect(std.mem.indexOf(u8, highlighted, "\x1b[") != null);
    // Should contain the original text
    const stripped = try stripColors(allocator, highlighted);
    defer allocator.free(stripped);
    try std.testing.expectEqualStrings(input, stripped);
}

test "highlight string literals" {
    const allocator = std.testing.allocator;
    const input = "RETURN 'hello' AS greeting";
    const highlighted = try highlight(allocator, input, true);
    defer allocator.free(highlighted);

    // Should contain green color for string
    try std.testing.expect(std.mem.indexOf(u8, highlighted, Color.green) != null);
}

test "highlight numbers" {
    const allocator = std.testing.allocator;
    const input = "RETURN 123 AS num, 45.67 AS float";
    const highlighted = try highlight(allocator, input, true);
    defer allocator.free(highlighted);

    // Should contain cyan color for numbers
    try std.testing.expect(std.mem.indexOf(u8, highlighted, Color.cyan) != null);
}

test "highlight meta commands" {
    const allocator = std.testing.allocator;
    const input = "\\help";
    const highlighted = try highlight(allocator, input, true);
    defer allocator.free(highlighted);

    // Should contain magenta color for meta command
    try std.testing.expect(std.mem.indexOf(u8, highlighted, Color.bright_magenta) != null);
}

test "highlight without colors" {
    const allocator = std.testing.allocator;
    const input = "MATCH (n) RETURN n";
    const highlighted = try highlight(allocator, input, false);
    defer allocator.free(highlighted);

    // Should be identical to input
    try std.testing.expectEqualStrings(input, highlighted);
}

test "stripColors removes ANSI codes" {
    const allocator = std.testing.allocator;
    const colored = "\x1b[34mMATCH\x1b[0m (n) \x1b[34mRETURN\x1b[0m n";
    const stripped = try stripColors(allocator, colored);
    defer allocator.free(stripped);

    try std.testing.expectEqualStrings("MATCH (n) RETURN n", stripped);
}
