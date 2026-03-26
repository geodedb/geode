// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;
const Graph = @import("graph.zig").Graph;
const graph_core = @import("graph_core.zig");
const matching = @import("matching.zig");

test "Hopcroft-Karp - basic bipartite matching" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    // U: u1, u2
    // V: v1, v2, v3
    // Edges: u1-v1, u1-v2, u2-v2, u2-v3
    // Expected matching size: 2
    const user1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "u1", 1);
    const user2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "u2", 2);
    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "v1", 3);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "v2", 4);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "v3", 5);

    try graph.addVertex(user1);
    try graph.addVertex(user2);
    try graph.addVertex(v1);
    try graph.addVertex(v2);
    try graph.addVertex(v3);

    const e_u1v1 = try graph_core.createEdge(i32, testing.allocator, user1, v1, 0, .{});
    const e_u1v2 = try graph_core.createEdge(i32, testing.allocator, user1, v2, 0, .{});
    const e_u2v2 = try graph_core.createEdge(i32, testing.allocator, user2, v2, 0, .{});
    const e_u2v3 = try graph_core.createEdge(i32, testing.allocator, user2, v3, 0, .{});

    try graph.addEdge(e_u1v1);
    try graph.addEdge(e_u1v2);
    try graph.addEdge(e_u2v2);
    try graph.addEdge(e_u2v3);

    const U = [_]*graph_core.Vertex(i32){ user1, user2 };
    const V = [_]*graph_core.Vertex(i32){ v1, v2, v3 };

    var result = try matching.hopcroftKarp(i32, &graph, &U, &V, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.size);
    try testing.expectEqual(@as(usize, 2), result.matching.count());
}

test "Hopcroft-Karp - perfect matching" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    // U: u1, user2, u3
    // V: v1, v2, v3
    // Complete bipartite graph K3,3
    const user1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "u1", 1);
    const user2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "u2", 2);
    const user3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "u3", 3);
    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "v1", 4);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "v2", 5);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "v3", 6);

    try graph.addVertex(user1);
    try graph.addVertex(user2);
    try graph.addVertex(user3);
    try graph.addVertex(v1);
    try graph.addVertex(v2);
    try graph.addVertex(v3);

    // Add all edges between U and V
    for ([_]*graph_core.Vertex(i32){ user1, user2, user3 }) |u| {
        for ([_]*graph_core.Vertex(i32){ v1, v2, v3 }) |v| {
            const e = try graph_core.createEdge(i32, testing.allocator, u, v, 0, .{});
            try graph.addEdge(e);
        }
    }

    const U = [_]*graph_core.Vertex(i32){ user1, user2, user3 };
    const V = [_]*graph_core.Vertex(i32){ v1, v2, v3 };

    var result = try matching.hopcroftKarp(i32, &graph, &U, &V, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.size);
}

test "Hopcroft-Karp - no matching" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    // U and V with no edges between them
    const user1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "u1", 1);
    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "v1", 2);

    try graph.addVertex(user1);
    try graph.addVertex(v1);

    const U = [_]*graph_core.Vertex(i32){user1};
    const V = [_]*graph_core.Vertex(i32){v1};

    var result = try matching.hopcroftKarp(i32, &graph, &U, &V, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.size);
}

test "Hopcroft-Karp - single edge" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const user1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "u1", 1);
    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "v1", 2);

    try graph.addVertex(user1);
    try graph.addVertex(v1);

    const e = try graph_core.createEdge(i32, testing.allocator, user1, v1, 0, .{});
    try graph.addEdge(e);

    const U = [_]*graph_core.Vertex(i32){user1};
    const V = [_]*graph_core.Vertex(i32){v1};

    var result = try matching.hopcroftKarp(i32, &graph, &U, &V, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.size);
    try testing.expect(result.matching.contains("u1"));
}

test "Hopcroft-Karp - asymmetric sets" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    // U: u1
    // V: v1, v2, v3
    // u1 connects to all V vertices
    const user1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "u1", 1);
    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "v1", 2);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "v2", 3);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "v3", 4);

    try graph.addVertex(user1);
    try graph.addVertex(v1);
    try graph.addVertex(v2);
    try graph.addVertex(v3);

    const e1 = try graph_core.createEdge(i32, testing.allocator, user1, v1, 0, .{});
    const e2 = try graph_core.createEdge(i32, testing.allocator, user1, v2, 0, .{});
    const e3 = try graph_core.createEdge(i32, testing.allocator, user1, v3, 0, .{});

    try graph.addEdge(e1);
    try graph.addEdge(e2);
    try graph.addEdge(e3);

    const U = [_]*graph_core.Vertex(i32){user1};
    const V = [_]*graph_core.Vertex(i32){ v1, v2, v3 };

    var result = try matching.hopcroftKarp(i32, &graph, &U, &V, testing.allocator);
    defer result.deinit();

    // Can only match 1 since |U| = 1
    try testing.expectEqual(@as(usize, 1), result.size);
}

test "Hopcroft-Karp - directed edges" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const user1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "u1", 1);
    const user2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "u2", 2);
    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "v1", 3);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "v2", 4);

    try graph.addVertex(user1);
    try graph.addVertex(user2);
    try graph.addVertex(v1);
    try graph.addVertex(v2);

    // Directed edges from U to V
    const e1 = try graph_core.createEdge(i32, testing.allocator, user1, v1, 0, .{ .directed = true });
    const e2 = try graph_core.createEdge(i32, testing.allocator, user2, v2, 0, .{ .directed = true });

    try graph.addEdge(e1);
    try graph.addEdge(e2);

    const U = [_]*graph_core.Vertex(i32){ user1, user2 };
    const V = [_]*graph_core.Vertex(i32){ v1, v2 };

    var result = try matching.hopcroftKarp(i32, &graph, &U, &V, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.size);
}

test "Hopcroft-Karp - augmenting paths" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    // U: u1, user2, u3
    // V: v1, v2, v3
    // Edges require augmenting paths for optimal matching
    const user1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "u1", 1);
    const user2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "u2", 2);
    const user3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "u3", 3);
    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "v1", 4);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "v2", 5);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "v3", 6);

    try graph.addVertex(user1);
    try graph.addVertex(user2);
    try graph.addVertex(user3);
    try graph.addVertex(v1);
    try graph.addVertex(v2);
    try graph.addVertex(v3);

    const e1 = try graph_core.createEdge(i32, testing.allocator, user1, v1, 0, .{});
    const e2 = try graph_core.createEdge(i32, testing.allocator, user1, v2, 0, .{});
    const e3 = try graph_core.createEdge(i32, testing.allocator, user2, v1, 0, .{});
    const e4 = try graph_core.createEdge(i32, testing.allocator, user2, v3, 0, .{});
    const e5 = try graph_core.createEdge(i32, testing.allocator, user3, v2, 0, .{});
    const e6 = try graph_core.createEdge(i32, testing.allocator, user3, v3, 0, .{});

    try graph.addEdge(e1);
    try graph.addEdge(e2);
    try graph.addEdge(e3);
    try graph.addEdge(e4);
    try graph.addEdge(e5);
    try graph.addEdge(e6);

    const U = [_]*graph_core.Vertex(i32){ user1, user2, user3 };
    const V = [_]*graph_core.Vertex(i32){ v1, v2, v3 };

    var result = try matching.hopcroftKarp(i32, &graph, &U, &V, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.size);
}
