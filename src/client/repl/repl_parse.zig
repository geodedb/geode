const std = @import("std");

pub fn isComplete(input: []const u8) bool {
    // Check for semicolon terminator
    if (std.mem.indexOf(u8, input, ";")) |_| {
        return true;
    }

    // If it's not terminated with semicolon, check if it's an incomplete GQL statement
    if (isIncompleteGqlStatement(input) or needsContinuation(input)) {
        return false;
    }

    // Check if balanced (for cases like standalone expressions)
    return isBalanced(input);
}

pub fn isBalanced(input: []const u8) bool {
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var in_string = false;
    var in_line_comment = false;
    var in_block_comment = false;
    var escape_next = false;

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];

        // Handle escape sequences in strings
        if (escape_next) {
            escape_next = false;
            continue;
        }

        // Handle comments
        if (!in_string) {
            if (!in_block_comment and i + 1 < input.len) {
                if (input[i] == '/' and input[i + 1] == '/') {
                    in_line_comment = true;
                    i += 1;
                    continue;
                } else if (input[i] == '/' and input[i + 1] == '*') {
                    in_block_comment = true;
                    i += 1;
                    continue;
                }
            }

            if (in_block_comment and i + 1 < input.len) {
                if (input[i] == '*' and input[i + 1] == '/') {
                    in_block_comment = false;
                    i += 1;
                    continue;
                }
            }

            if (in_line_comment and c == '\n') {
                in_line_comment = false;
                continue;
            }
        }

        if (in_line_comment or in_block_comment) {
            continue;
        }

        // Handle strings
        if (c == '"' and !in_string) {
            in_string = true;
            continue;
        } else if (c == '"' and in_string) {
            in_string = false;
            continue;
        }

        if (in_string) {
            if (c == '\\') {
                escape_next = true;
            }
            continue;
        }

        // Count brackets
        switch (c) {
            '(' => paren_depth += 1,
            ')' => {
                paren_depth -= 1;
                if (paren_depth < 0) return false;
            },
            '[' => bracket_depth += 1,
            ']' => {
                bracket_depth -= 1;
                if (bracket_depth < 0) return false;
            },
            '{' => brace_depth += 1,
            '}' => {
                brace_depth -= 1;
                if (brace_depth < 0) return false;
            },
            else => {},
        }
    }

    return paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and !in_string and !in_block_comment;
}

pub fn needsContinuation(input: []const u8) bool {
    if (input.len == 0) return false;

    // Check for obvious incomplete GQL statements first
    if (isIncompleteGqlStatement(input)) return true;

    // Check if last non-whitespace character suggests continuation
    var i = input.len;
    while (i > 0) : (i -= 1) {
        const c = input[i - 1];
        if (!std.ascii.isWhitespace(c)) {
            return switch (c) {
                ',', '+', '-', '*', '/', '=', '<', '>', '(', '[', '{' => true,
                else => false,
            };
        }
    }

    return false;
}

pub fn isIncompleteGqlStatement(input: []const u8) bool {
    // Convert to uppercase for case-insensitive matching
    var upper_input: [1024]u8 = undefined;
    if (input.len >= upper_input.len) return false;
    
    for (input, 0..) |c, i| {
        upper_input[i] = std.ascii.toUpper(c);
    }
    const upper_slice = upper_input[0..input.len];
    
    // Common GQL statement patterns that need continuation
    const incomplete_patterns = [_][]const u8{
        "MATCH",
        "CREATE", 
        "DELETE",
        "SET",
        "REMOVE",
        "WITH",
        "WHERE",
        "RETURN",
        "ORDER BY",
        "OPTIONAL",
        "MERGE",
        "CALL",
        "USE",
        "DROP",
        "SHOW",
        "ALTER",
        "START",
    };
    
    // Check if input ends with an incomplete GQL keyword
    for (incomplete_patterns) |pattern| {
        if (std.mem.endsWith(u8, upper_slice, pattern)) {
            return true;
        }
        
        // Also check for keyword followed by whitespace but no semicolon
        var pattern_with_space: [64]u8 = undefined;
        const pattern_space = std.fmt.bufPrint(&pattern_with_space, "{s} ", .{pattern}) catch continue;
        if (std.mem.indexOf(u8, upper_slice, pattern_space) != null and 
            std.mem.indexOf(u8, input, ";") == null) {
            // Check if there's meaningful content after the keyword
            const keyword_end = std.mem.indexOf(u8, upper_slice, pattern_space).? + pattern_space.len;
            const remaining = std.mem.trim(u8, input[keyword_end..], " \t\n\r");
            
            // If there's some content but no semicolon, likely needs continuation
            if (remaining.len > 0 and remaining.len < 20) {
                return true;
            }
        }
    }
    
    return false;
}

test "parser balance" {
    try std.testing.expect(!isBalanced("MATCH (n"));
    try std.testing.expect(isBalanced("MATCH (n)\nRETURN n;"));
    try std.testing.expect(!isBalanced("MATCH (n) WHERE n.prop = \"unclosed string"));
    try std.testing.expect(isBalanced("MATCH (n) WHERE n.prop = \"closed string\""));
    try std.testing.expect(!isBalanced("MATCH /* unclosed comment"));
    try std.testing.expect(isBalanced("MATCH /* closed comment */"));
}

test "multi-line parsing" {
    const testing = std.testing;
    
    // Test continuation detection
    try testing.expect(needsContinuation("MATCH"));
    try testing.expect(needsContinuation("MATCH (n)"));
    try testing.expect(needsContinuation("MATCH (n) WHERE"));
    try testing.expect(needsContinuation("CREATE ("));
    try testing.expect(!needsContinuation("RETURN 1;"));
    try testing.expect(!needsContinuation(""));
    
    // Test incomplete statement detection
    try testing.expect(isIncompleteGqlStatement("MATCH"));
    try testing.expect(isIncompleteGqlStatement("CREATE"));
    try testing.expect(isIncompleteGqlStatement("MATCH (n)"));
    try testing.expect(isIncompleteGqlStatement("MATCH (n) WHERE n.age"));
    try testing.expect(!isIncompleteGqlStatement("RETURN 1;"));
    try testing.expect(!isIncompleteGqlStatement("SELECT * FROM table;"));
    
    // Test complete multi-line statements
    try testing.expect(isComplete("MATCH (n)\nRETURN n;"));
    try testing.expect(isComplete("MATCH (n)\nWHERE n.age > 25\nRETURN n.name;"));
    try testing.expect(!isComplete("MATCH (n)"));
    try testing.expect(!isComplete("MATCH (n)\nWHERE n.age > 25"));
}
