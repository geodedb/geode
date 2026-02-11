// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;
const gql = @import("gql.zig");
const Graph = @import("graph.zig").Graph;
const Vertex = @import("graph_core.zig").Vertex;
const createEdge = @import("graph_core.zig").createEdge;
const EdgeOptions = @import("graph_core.zig").EdgeOptions;

test "GQL - emitCreateGQL basic directed graph" {
    var graph = Graph([]const u8).init(testing.allocator);
    defer graph.deinit();

    // Use string literals - initWithId already duplicates the ID
    const a = try Vertex([]const u8).initWithId(testing.allocator, "A", "");
    const b = try Vertex([]const u8).initWithId(testing.allocator, "B", "");

    graph.addVertex(a);
    graph.addVertex(b);

    const edge = try createEdge([]const u8, testing.allocator, a, b, "", .{ .directed = true, .weighted = false, .weight = 0 });
    graph.addEdge(edge);

    var result = try gql.emitCreateGQL([]const u8, &graph, testing.allocator);
    defer result.deinit();

    // Verify query starts with CREATE
    try testing.expect(std.mem.startsWith(u8, result.query, "CREATE "));

    // Verify contains node declarations
    try testing.expect(std.mem.indexOf(u8, result.query, ":Node {id: $") != null);

    // Verify contains directed edge
    try testing.expect(std.mem.indexOf(u8, result.query, "-[:REL]->") != null);

    // Verify params
    try testing.expectEqual(@as(usize, 2), result.params.count());
}

test "GQL - emitCreateGQL deterministic ordering" {
    var graph = Graph([]const u8).init(testing.allocator);
    defer graph.deinit();

    // Create vertices out of alphabetical order
    const c = try Vertex([]const u8).initWithId(testing.allocator, "C", "");
    const a = try Vertex([]const u8).initWithId(testing.allocator, "A", "");
    const b = try Vertex([]const u8).initWithId(testing.allocator, "B", "");

    graph.addVertex(c);
    graph.addVertex(a);
    graph.addVertex(b);

    // Add edges out of order
    const edge2 = try createEdge([]const u8, testing.allocator, b, c, "", .{ .directed = true, .weighted = false, .weight = 0 });
    const edge1 = try createEdge([]const u8, testing.allocator, a, b, "", .{ .directed = true, .weighted = false, .weight = 0 });
    graph.addEdge(edge2);
    graph.addEdge(edge1);

    var result = try gql.emitCreateGQL([]const u8, &graph, testing.allocator);
    defer result.deinit();

    // Count nodes and edges
    const node_count = std.mem.count(u8, result.query, ":Node {id: $");
    try testing.expectEqual(@as(usize, 3), node_count);

    const edge_count = std.mem.count(u8, result.query, "-[:REL]->");
    try testing.expectEqual(@as(usize, 2), edge_count);

    // Verify params
    try testing.expectEqual(@as(usize, 3), result.params.count());
}

test "GQL - emitCreateGQL undirected graph" {
    var graph = Graph([]const u8).init(testing.allocator);
    defer graph.deinit();

    const a = try Vertex([]const u8).initWithId(testing.allocator, "A", "");
    const b = try Vertex([]const u8).initWithId(testing.allocator, "B", "");

    graph.addVertex(a);
    graph.addVertex(b);

    const edge = try createEdge([]const u8, testing.allocator, a, b, "", .{ .directed = false, .weighted = false, .weight = 0 });
    graph.addEdge(edge);

    var result = try gql.emitCreateGQL([]const u8, &graph, testing.allocator);
    defer result.deinit();

    // Verify undirected edge pattern (no arrow)
    try testing.expect(std.mem.indexOf(u8, result.query, "-[:REL]-(") != null);
    try testing.expect(std.mem.indexOf(u8, result.query, "-[:REL]->") == null);
}

test "GQL - emitCreateGQL empty graph" {
    var graph = Graph([]const u8).init(testing.allocator);
    defer graph.deinit();

    var result = try gql.emitCreateGQL([]const u8, &graph, testing.allocator);
    defer result.deinit();

    // Empty graph should still have CREATE prefix
    try testing.expect(result.query.len >= 6); // At least "CREATE"
    try testing.expectEqual(@as(usize, 0), result.params.count());
}

test "GQL - emitCreateGQL single node" {
    var graph = Graph([]const u8).init(testing.allocator);
    defer graph.deinit();

    const a = try Vertex([]const u8).initWithId(testing.allocator, "A", "");
    graph.addVertex(a);

    var result = try gql.emitCreateGQL([]const u8, &graph, testing.allocator);
    defer result.deinit();

    try testing.expect(std.mem.startsWith(u8, result.query, "CREATE "));
    try testing.expectEqual(@as(usize, 1), result.params.count());

    // Should have one node, no edges
    const node_count = std.mem.count(u8, result.query, ":Node {id: $");
    try testing.expectEqual(@as(usize, 1), node_count);
}

test "GQL - emitCreateGQL with special characters in ID" {
    var graph = Graph([]const u8).init(testing.allocator);
    defer graph.deinit();

    const v1 = try Vertex([]const u8).initWithId(testing.allocator, "node-1", "");
    const v2 = try Vertex([]const u8).initWithId(testing.allocator, "node@2", "");

    graph.addVertex(v1);
    graph.addVertex(v2);

    var result = try gql.emitCreateGQL([]const u8, &graph, testing.allocator);
    defer result.deinit();

    // Should have sanitized IDs (special chars replaced with _)
    try testing.expect(std.mem.indexOf(u8, result.query, "node_1") != null);
    try testing.expect(std.mem.indexOf(u8, result.query, "node_2") != null);
}

test "GQL - emitCreateGQL parameter names" {
    var graph = Graph([]const u8).init(testing.allocator);
    defer graph.deinit();

    const a = try Vertex([]const u8).initWithId(testing.allocator, "A", "");
    graph.addVertex(a);

    var result = try gql.emitCreateGQL([]const u8, &graph, testing.allocator);
    defer result.deinit();

    // Verify parameter naming convention
    try testing.expect(result.params.contains("nid_A"));
    try testing.expectEqualStrings("A", result.params.get("nid_A").?);
}

test "GQL - emitMatchShortestPathGQL basic" {
    var result = try gql.emitMatchShortestPathGQL("A", "C", testing.allocator);
    defer result.deinit();

    // Verify query contains expected components
    try testing.expect(std.mem.indexOf(u8, result.query, "MATCH") != null);
    try testing.expect(std.mem.indexOf(u8, result.query, "shortestPath") != null);
    try testing.expect(std.mem.indexOf(u8, result.query, "$sid") != null);
    try testing.expect(std.mem.indexOf(u8, result.query, "$tid") != null);
    try testing.expect(std.mem.indexOf(u8, result.query, "RETURN p") != null);

    // Verify params
    try testing.expectEqual(@as(usize, 2), result.params.count());
    try testing.expectEqualStrings("A", result.params.get("sid").?);
    try testing.expectEqualStrings("C", result.params.get("tid").?);
}

test "GQL - emitMatchShortestPathGQL empty IDs" {
    // Empty start ID
    const result1 = gql.emitMatchShortestPathGQL("", "C", testing.allocator);
    try testing.expectError(error.EmptyID, result1);

    // Empty end ID
    const result2 = gql.emitMatchShortestPathGQL("A", "", testing.allocator);
    try testing.expectError(error.EmptyID, result2);

    // Both empty
    const result3 = gql.emitMatchShortestPathGQL("", "", testing.allocator);
    try testing.expectError(error.EmptyID, result3);
}

test "GQL - emitMatchShortestPathGQL with special characters" {
    var result = try gql.emitMatchShortestPathGQL("node-1", "node@2", testing.allocator);
    defer result.deinit();

    // Parameters should preserve original IDs (not sanitized)
    try testing.expectEqualStrings("node-1", result.params.get("sid").?);
    try testing.expectEqualStrings("node@2", result.params.get("tid").?);
}

test "GQL - sanitize ID alphanumeric" {
    const allocator = testing.allocator;

    const result1 = try gql.sanitizeID("abc123", allocator);
    defer allocator.free(result1);
    try testing.expectEqualStrings("abc123", result1);

    const result2 = try gql.sanitizeID("ABC", allocator);
    defer allocator.free(result2);
    try testing.expectEqualStrings("ABC", result2);
}

test "GQL - sanitize ID with special characters" {
    const allocator = testing.allocator;

    const result1 = try gql.sanitizeID("node-1", allocator);
    defer allocator.free(result1);
    try testing.expectEqualStrings("node_1", result1);

    const result2 = try gql.sanitizeID("node@2#test", allocator);
    defer allocator.free(result2);
    try testing.expectEqualStrings("node_2_test", result2);

    const result3 = try gql.sanitizeID("a.b.c", allocator);
    defer allocator.free(result3);
    try testing.expectEqualStrings("a_b_c", result3);
}

test "GQL - sanitize ID empty" {
    const allocator = testing.allocator;

    const result = try gql.sanitizeID("", allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings("_", result);
}

test "GQL - sanitize ID only special characters" {
    const allocator = testing.allocator;

    const result = try gql.sanitizeID("@#$%", allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings("____", result);
}

// Acceptance test matching Go implementation
test "Acceptance - GQL emitCreateGQL deterministic" {
    var graph = Graph([]const u8).init(testing.allocator);
    defer graph.deinit();

    const a = try Vertex([]const u8).initWithId(testing.allocator, "A", "");
    const b = try Vertex([]const u8).initWithId(testing.allocator, "B", "");
    const c = try Vertex([]const u8).initWithId(testing.allocator, "C", "");

    graph.addVertex(a);
    graph.addVertex(b);
    graph.addVertex(c);

    // Add edges out of order intentionally
    const edge2 = try createEdge([]const u8, testing.allocator, b, c, "", .{ .directed = true, .weighted = false, .weight = 0 });
    const edge1 = try createEdge([]const u8, testing.allocator, a, b, "", .{ .directed = true, .weighted = false, .weight = 0 });
    graph.addEdge(edge2);
    graph.addEdge(edge1);

    var result = try gql.emitCreateGQL([]const u8, &graph, testing.allocator);
    defer result.deinit();

    try testing.expect(std.mem.startsWith(u8, result.query, "CREATE "));

    // Ensure 3 node fragments and 2 edge fragments present
    const node_count = std.mem.count(u8, result.query, ":Node {id: $");
    try testing.expectEqual(@as(usize, 3), node_count);

    const edge_dir_count = std.mem.count(u8, result.query, "-[:REL]->");
    try testing.expectEqual(@as(usize, 2), edge_dir_count);

    // Params size must be 3
    try testing.expectEqual(@as(usize, 3), result.params.count());
}

// Acceptance test matching Go implementation
test "Acceptance - GQL emitMatchShortestPathGQL" {
    var result = try gql.emitMatchShortestPathGQL("A", "C", testing.allocator);
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.query, "shortestPath") != null);
    try testing.expectEqualStrings("A", result.params.get("sid").?);
    try testing.expectEqualStrings("C", result.params.get("tid").?);
}
