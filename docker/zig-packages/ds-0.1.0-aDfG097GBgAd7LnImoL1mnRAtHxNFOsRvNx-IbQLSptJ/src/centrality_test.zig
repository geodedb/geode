// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;
const Graph = @import("graph.zig").Graph;
const graph_core = @import("graph_core.zig");
const centrality = @import("centrality.zig");

test "PageRank - basic directed graph" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    // A->B, A->C, B->C, C->A, C->D
    // C should have highest rank (most incoming)
    const a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const b = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const c = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);
    const d = try graph_core.Vertex(i32).initWithId(testing.allocator, "D", 4);

    graph.addVertex(a);
    graph.addVertex(b);
    graph.addVertex(c);
    graph.addVertex(d);

    const e_ab = try graph_core.createEdge(i32, testing.allocator, a, b, 0, .{ .directed = true });
    const e_ac = try graph_core.createEdge(i32, testing.allocator, a, c, 0, .{ .directed = true });
    const e_bc = try graph_core.createEdge(i32, testing.allocator, b, c, 0, .{ .directed = true });
    const e_ca = try graph_core.createEdge(i32, testing.allocator, c, a, 0, .{ .directed = true });
    const e_cd = try graph_core.createEdge(i32, testing.allocator, c, d, 0, .{ .directed = true });

    graph.addEdge(e_ab);
    graph.addEdge(e_ac);
    graph.addEdge(e_bc);
    graph.addEdge(e_ca);
    graph.addEdge(e_cd);

    var result = try centrality.pageRank(i32, &graph, 0.85, 1e-8, 200, testing.allocator);
    defer result.deinit();

    const c_rank = result.scores.get("C") orelse 0;
    const a_rank = result.scores.get("A") orelse 0;
    const b_rank = result.scores.get("B") orelse 0;

    // C should have higher rank than A and B
    try testing.expect(c_rank > a_rank);
    try testing.expect(a_rank > b_rank);
}

test "PageRank - convergence" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const b = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);

    graph.addVertex(a);
    graph.addVertex(b);

    const e = try graph_core.createEdge(i32, testing.allocator, a, b, 0, .{ .directed = true });
    graph.addEdge(e);

    var result = try centrality.pageRank(i32, &graph, 0.85, 1e-8, 200, testing.allocator);
    defer result.deinit();

    // Should converge before max iterations
    try testing.expect(result.iterations < 200);
}

test "PageRank - single vertex" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    graph.addVertex(a);

    var result = try centrality.pageRank(i32, &graph, 0.85, 1e-8, 100, testing.allocator);
    defer result.deinit();

    const a_rank = result.scores.get("A") orelse 0;
    try testing.expectApproxEqAbs(@as(f64, 1.0), a_rank, 1e-6);
}

test "PageRank - sink node handling" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    // A->B, B has no outgoing edges (sink)
    const a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const b = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const c = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    graph.addVertex(a);
    graph.addVertex(b);
    graph.addVertex(c);

    const e_ab = try graph_core.createEdge(i32, testing.allocator, a, b, 0, .{ .directed = true });
    const e_ac = try graph_core.createEdge(i32, testing.allocator, a, c, 0, .{ .directed = true });

    graph.addEdge(e_ab);
    graph.addEdge(e_ac);

    var result = try centrality.pageRank(i32, &graph, 0.85, 1e-8, 100, testing.allocator);
    defer result.deinit();

    // All vertices should have non-zero rank
    try testing.expect(result.scores.get("A").? > 0);
    try testing.expect(result.scores.get("B").? > 0);
    try testing.expect(result.scores.get("C").? > 0);
}

test "Centrality - linear graph betweenness" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    // A-B-C-D (linear chain)
    // B and C should have higher betweenness
    const a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const b = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const c = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);
    const d = try graph_core.Vertex(i32).initWithId(testing.allocator, "D", 4);

    graph.addVertex(a);
    graph.addVertex(b);
    graph.addVertex(c);
    graph.addVertex(d);

    const e_ab = try graph_core.createEdge(i32, testing.allocator, a, b, 0, .{});
    const e_bc = try graph_core.createEdge(i32, testing.allocator, b, c, 0, .{});
    const e_cd = try graph_core.createEdge(i32, testing.allocator, c, d, 0, .{});

    graph.addEdge(e_ab);
    graph.addEdge(e_bc);
    graph.addEdge(e_cd);

    var result = try centrality.computeCentrality(i32, &graph, testing.allocator);
    defer result.deinit();

    const bet_a = result.betweenness.get("A") orelse 0;
    const bet_b = result.betweenness.get("B") orelse 0;
    const bet_c = result.betweenness.get("C") orelse 0;

    // B and C should have higher betweenness than A
    try testing.expect(bet_b > bet_a);
    try testing.expect(bet_c > bet_a);
}

test "Centrality - closeness in linear graph" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    // A-B-C-D
    // B and C should have higher closeness (more central)
    const a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const b = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const c = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);
    const d = try graph_core.Vertex(i32).initWithId(testing.allocator, "D", 4);

    graph.addVertex(a);
    graph.addVertex(b);
    graph.addVertex(c);
    graph.addVertex(d);

    const e_ab = try graph_core.createEdge(i32, testing.allocator, a, b, 0, .{});
    const e_bc = try graph_core.createEdge(i32, testing.allocator, b, c, 0, .{});
    const e_cd = try graph_core.createEdge(i32, testing.allocator, c, d, 0, .{});

    graph.addEdge(e_ab);
    graph.addEdge(e_bc);
    graph.addEdge(e_cd);

    var result = try centrality.computeCentrality(i32, &graph, testing.allocator);
    defer result.deinit();

    const close_a = result.closeness.get("A") orelse 0;
    const close_b = result.closeness.get("B") orelse 0;

    // B should have higher closeness than A
    try testing.expect(close_b > close_a);
}

test "Centrality - star graph" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    // Center connected to 4 leaves
    const center = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 0);
    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "1", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "2", 2);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "3", 3);
    const v4 = try graph_core.Vertex(i32).initWithId(testing.allocator, "4", 4);

    graph.addVertex(center);
    graph.addVertex(v1);
    graph.addVertex(v2);
    graph.addVertex(v3);
    graph.addVertex(v4);

    const e1 = try graph_core.createEdge(i32, testing.allocator, center, v1, 0, .{});
    const e2 = try graph_core.createEdge(i32, testing.allocator, center, v2, 0, .{});
    const e3 = try graph_core.createEdge(i32, testing.allocator, center, v3, 0, .{});
    const e4 = try graph_core.createEdge(i32, testing.allocator, center, v4, 0, .{});

    graph.addEdge(e1);
    graph.addEdge(e2);
    graph.addEdge(e3);
    graph.addEdge(e4);

    var result = try centrality.computeCentrality(i32, &graph, testing.allocator);
    defer result.deinit();

    const bet_center = result.betweenness.get("C") orelse 0;
    const bet_leaf = result.betweenness.get("1") orelse 0;

    // Center should have much higher betweenness
    try testing.expect(bet_center > bet_leaf);
}

test "Centrality - directed graph" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const b = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const c = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    graph.addVertex(a);
    graph.addVertex(b);
    graph.addVertex(c);

    const e_ab = try graph_core.createEdge(i32, testing.allocator, a, b, 0, .{ .directed = true });
    const e_bc = try graph_core.createEdge(i32, testing.allocator, b, c, 0, .{ .directed = true });

    graph.addEdge(e_ab);
    graph.addEdge(e_bc);

    var result = try centrality.computeCentrality(i32, &graph, testing.allocator);
    defer result.deinit();

    const bet_b = result.betweenness.get("B") orelse 0;
    const bet_a = result.betweenness.get("A") orelse 0;

    // B is on path from A to C
    try testing.expect(bet_b > bet_a);
}

test "Centrality - single vertex" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    graph.addVertex(a);

    var result = try centrality.computeCentrality(i32, &graph, testing.allocator);
    defer result.deinit();

    const bet_a = result.betweenness.get("A") orelse 0;
    try testing.expectEqual(@as(f64, 0), bet_a);
}

test "Centrality - disconnected components" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    // Two disconnected pairs: A-B and C-D
    const a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const b = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const c = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);
    const d = try graph_core.Vertex(i32).initWithId(testing.allocator, "D", 4);

    graph.addVertex(a);
    graph.addVertex(b);
    graph.addVertex(c);
    graph.addVertex(d);

    const e_ab = try graph_core.createEdge(i32, testing.allocator, a, b, 0, .{});
    const e_cd = try graph_core.createEdge(i32, testing.allocator, c, d, 0, .{});

    graph.addEdge(e_ab);
    graph.addEdge(e_cd);

    var result = try centrality.computeCentrality(i32, &graph, testing.allocator);
    defer result.deinit();

    // All vertices should have zero betweenness (no vertex is between others across components)
    const bet_a = result.betweenness.get("A") orelse 0;
    try testing.expectEqual(@as(f64, 0), bet_a);
}
