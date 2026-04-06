const std = @import("std");

pub fn startsWithUseGraph(query_text: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, query_text, " \t\r\n");
    if (trimmed.len < 9) return false;
    return std.ascii.eqlIgnoreCase(trimmed[0..9], "USE GRAPH");
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
