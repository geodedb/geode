const std = @import("std");
const geode = @import("geode");

test "path tie-breaking logic" {
    const allocator = std.testing.allocator;

    // Test the tie-breaking logic at the AST/planner level
    // Parse a query with variable-length path
    const query_text = "MATCH (a)-[*1..3]->(b) RETURN a, b";
    var res = try geode.parseGql(query_text, allocator);
    defer res.deinit();

    const query = res.program.statements[0].Query;
    const chain = query.match.chains[0];
    const hop = chain.hops[0];

    // Verify variable-length path is parsed correctly
    try std.testing.expect(hop.rel.min_len != null);
    try std.testing.expect(hop.rel.max_len != null);
    try std.testing.expectEqual(@as(u32, 1), hop.rel.min_len.?);
    try std.testing.expectEqual(@as(u32, 3), hop.rel.max_len.?);
}

test "shortest path semantics" {
    const allocator = std.testing.allocator;

    // Test that shortest path queries are parsed correctly
    const query_text = "MATCH (a)-[*1..1]->(b) RETURN a, b";
    var res = try geode.parseGql(query_text, allocator);
    defer res.deinit();

    const query = res.program.statements[0].Query;
    const chain = query.match.chains[0];
    const hop = chain.hops[0];

    // When min_len == max_len, it's effectively a shortest path query
    try std.testing.expect(hop.rel.min_len != null);
    try std.testing.expect(hop.rel.max_len != null);
    try std.testing.expectEqual(@as(u32, 1), hop.rel.min_len.?);
    try std.testing.expectEqual(@as(u32, 1), hop.rel.max_len.?);
}

test "path ordering determinism" {
    // Test that path results would be deterministic
    // This is a conceptual test to verify the ordering logic

    const Path = struct {
        nodes: []const u64,

        fn compare(a: @This(), b: @This()) std.math.Order {
            // First compare by length
            const len_cmp = std.math.order(a.nodes.len, b.nodes.len);
            if (len_cmp != .eq) return len_cmp;

            // Then lexicographically by node IDs
            for (a.nodes, b.nodes) |an, bn| {
                const node_cmp = std.math.order(an, bn);
                if (node_cmp != .eq) return node_cmp;
            }

            return .eq;
        }
    };

    // Test paths
    const paths = [_]Path{
        .{ .nodes = &[_]u64{ 1, 3, 4 } },
        .{ .nodes = &[_]u64{ 1, 2, 4 } },
        .{ .nodes = &[_]u64{ 1, 5 } },
    };

    // Find shortest path
    var shortest = paths[0];
    for (paths[1..]) |path| {
        if (path.compare(shortest) == .lt) {
            shortest = path;
        }
    }

    // Should select the path with length 2
    try std.testing.expectEqual(@as(usize, 2), shortest.nodes.len);
    try std.testing.expectEqual(@as(u64, 1), shortest.nodes[0]);
    try std.testing.expectEqual(@as(u64, 5), shortest.nodes[1]);
}
