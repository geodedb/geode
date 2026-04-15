const std = @import("std");

pub const LeadingUseGraph = struct {
    graph_name: []const u8,
    remainder: []const u8,
};

fn isGraphIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isGraphIdentContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn startsWithUseGraph(query_text: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, query_text, " \t\r\n");
    if (trimmed.len < 9) return false;
    return std.ascii.eqlIgnoreCase(trimmed[0..9], "USE GRAPH");
}

pub fn extractLeadingUseGraph(query_text: []const u8) ?LeadingUseGraph {
    var idx: usize = 0;
    while (idx < query_text.len and std.ascii.isWhitespace(query_text[idx])) : (idx += 1) {}

    const trimmed = query_text[idx..];
    if (trimmed.len < 9 or !std.ascii.eqlIgnoreCase(trimmed[0..9], "USE GRAPH")) return null;
    if (trimmed.len > 9 and !std.ascii.isWhitespace(trimmed[9])) return null;

    var pos = idx + 9;
    while (pos < query_text.len and std.ascii.isWhitespace(query_text[pos])) : (pos += 1) {}
    if (pos >= query_text.len or !isGraphIdentStart(query_text[pos])) return null;

    const graph_start = pos;
    pos += 1;
    while (pos < query_text.len and isGraphIdentContinue(query_text[pos])) : (pos += 1) {}
    const graph_end = pos;

    while (pos < query_text.len and std.ascii.isWhitespace(query_text[pos])) : (pos += 1) {}
    if (pos >= query_text.len or query_text[pos] != ';') return null;
    pos += 1;

    while (pos < query_text.len and std.ascii.isWhitespace(query_text[pos])) : (pos += 1) {}

    return .{
        .graph_name = query_text[graph_start..graph_end],
        .remainder = query_text[pos..],
    };
}

pub fn prependGraphContextIfNeeded(
    allocator: std.mem.Allocator,
    query_text: []const u8,
    graph: ?[]const u8,
) !?[]u8 {
    const graph_name = graph orelse return null;
    if (startsWithUseGraph(query_text)) return null;
    // Defense-in-depth: validate graph name is a safe identifier [a-zA-Z_][a-zA-Z0-9_]*
    if (graph_name.len == 0) return error.InvalidGraphName;
    if (!std.ascii.isAlphabetic(graph_name[0]) and graph_name[0] != '_') return error.InvalidGraphName;
    for (graph_name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return error.InvalidGraphName;
    }
    return try std.fmt.allocPrint(allocator, "USE GRAPH {s}; {s}", .{ graph_name, query_text });
}

test "startsWithUseGraph trims leading whitespace" {
    try std.testing.expect(startsWithUseGraph("  \n\tUSE GRAPH test_graph_ctx; MATCH (n) RETURN n;"));
}

test "startsWithUseGraph is case insensitive" {
    try std.testing.expect(startsWithUseGraph("use graph test_graph_ctx;"));
}

test "startsWithUseGraph rejects ordinary match query" {
    try std.testing.expect(!startsWithUseGraph("MATCH (n) RETURN COUNT(n);"));
}

test "prependGraphContextIfNeeded prefixes plain query" {
    const allocator = std.testing.allocator;
    const scoped = (try prependGraphContextIfNeeded(allocator, "MATCH (n) RETURN n;", "test_graph_ctx")).?;
    defer allocator.free(scoped);

    try std.testing.expectEqualStrings("USE GRAPH test_graph_ctx; MATCH (n) RETURN n;", scoped);
}

test "prependGraphContextIfNeeded skips explicit use graph" {
    const allocator = std.testing.allocator;
    try std.testing.expect((try prependGraphContextIfNeeded(allocator, "USE GRAPH other; RETURN 1;", "test_graph_ctx")) == null);
}

test "extractLeadingUseGraph returns graph and remainder" {
    const parsed = extractLeadingUseGraph("  USE GRAPH test_graph_ctx; MATCH (n) RETURN n;").?;
    try std.testing.expectEqualStrings("test_graph_ctx", parsed.graph_name);
    try std.testing.expectEqualStrings("MATCH (n) RETURN n;", parsed.remainder);
}

test "extractLeadingUseGraph returns empty remainder for lone statement" {
    const parsed = extractLeadingUseGraph("USE GRAPH test_graph_ctx;").?;
    try std.testing.expectEqualStrings("test_graph_ctx", parsed.graph_name);
    try std.testing.expectEqualStrings("", parsed.remainder);
}

test "extractLeadingUseGraph rejects invalid graph identifier" {
    try std.testing.expect(extractLeadingUseGraph("USE GRAPH 123bad; MATCH (n) RETURN n;") == null);
}
