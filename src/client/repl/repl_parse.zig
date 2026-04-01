const std = @import("std");
// CANARY: REQ=REQ-LIB-MIGRATION-REPL-001; FEATURE="External Library Migration"; ASPECT=ReplParseDelegation; STATUS=TESTED; TEST=test_repl_multi_line_parsing; OWNER=client; UPDATED=2026-04-01
const repl_lib = @import("repl");

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
    return repl_lib.isBalanced(input);
}

pub fn needsContinuation(input: []const u8) bool {
    if (input.len == 0) return false;

    // Layer Geode-specific GQL detection on top of the generic REPL parser.
    if (isIncompleteGqlStatement(input)) return true;
    return repl_lib.needsContinuation(input);
}

pub fn isIncompleteGqlStatement(input: []const u8) bool {
    const trimmed = std.mem.trim(u8, input, " \t\n\r");
    if (trimmed.len == 0) return false;

    // Convert to uppercase for case-insensitive matching
    var upper_input: [4096]u8 = undefined;
    if (trimmed.len >= upper_input.len) return false;

    for (trimmed, 0..) |c, i| {
        upper_input[i] = std.ascii.toUpper(c);
    }
    const upper_slice = upper_input[0..trimmed.len];

    // Keywords that when appearing at the END of input indicate incompleteness
    const trailing_keywords = [_][]const u8{
        "MATCH",
        "CREATE",
        "DELETE",
        "SET",
        "REMOVE",
        "WITH",
        "WHERE",
        "RETURN",
        "ORDER",
        "ORDER BY",
        "BY",
        "OPTIONAL",
        "MERGE",
        "CALL",
        "USE",
        "DROP",
        "SHOW",
        "ALTER",
        "START",
        "AND",
        "OR",
        "AS",
        "LIMIT",
        "SKIP",
        "UNION",
        "UNWIND",
    };

    // Check if input ends with an incomplete GQL keyword
    for (trailing_keywords) |pattern| {
        if (std.mem.endsWith(u8, upper_slice, pattern)) {
            // Make sure it's a word boundary (not part of a larger identifier)
            if (upper_slice.len == pattern.len) return true;
            const char_before = upper_slice[upper_slice.len - pattern.len - 1];
            if (!std.ascii.isAlphanumeric(char_before) and char_before != '_') {
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

    // Test continuation detection (trailing operators/brackets)
    try testing.expect(needsContinuation("MATCH"));
    try testing.expect(needsContinuation("CREATE ("));
    try testing.expect(!needsContinuation("RETURN 1;"));
    try testing.expect(!needsContinuation(""));

    // Test incomplete statement detection (trailing keywords)
    try testing.expect(isIncompleteGqlStatement("MATCH"));
    try testing.expect(isIncompleteGqlStatement("CREATE"));
    try testing.expect(isIncompleteGqlStatement("MATCH (n) WHERE"));
    try testing.expect(isIncompleteGqlStatement("ORDER BY"));
    try testing.expect(!isIncompleteGqlStatement("RETURN n"));
    try testing.expect(!isIncompleteGqlStatement("ORDER BY n.age DESC"));
    try testing.expect(!isIncompleteGqlStatement("RETURN 1;"));

    // Test complete multi-line statements
    try testing.expect(isComplete("MATCH (n)\nRETURN n;"));
    try testing.expect(isComplete("MATCH (n)\nWHERE n.age > 25\nRETURN n.name;"));
    try testing.expect(isComplete("MATCH (n) RETURN n")); // Complete without semicolon
    try testing.expect(isComplete("MATCH (n) WHERE n.age > 25 RETURN n.name ORDER BY n.age DESC"));
    try testing.expect(!isComplete("MATCH (n) WHERE")); // Ends with keyword
    try testing.expect(!isComplete("MATCH")); // Just keyword
}
