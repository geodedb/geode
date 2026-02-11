// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;
const Graph = @import("graph.zig").Graph;
const graph_core = @import("graph_core.zig");
const connectivity = @import("connectivity.zig");

test "SCC Tarjan - strongly connected components" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    // Create graph with components: {A,B,C} forming cycle A->B->C->A; {D,E} cycle; {F} singleton
    const v_a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v_b = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v_c = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);
    const v_d = try graph_core.Vertex(i32).initWithId(testing.allocator, "D", 4);
    const v_e = try graph_core.Vertex(i32).initWithId(testing.allocator, "E", 5);
    const v_f = try graph_core.Vertex(i32).initWithId(testing.allocator, "F", 6);

    graph.addVertex(v_a);
    graph.addVertex(v_b);
    graph.addVertex(v_c);
    graph.addVertex(v_d);
    graph.addVertex(v_e);
    graph.addVertex(v_f);

    const e_ab = try graph_core.createEdge(i32, testing.allocator, v_a, v_b, 0, .{ .directed = true });
    const e_bc = try graph_core.createEdge(i32, testing.allocator, v_b, v_c, 0, .{ .directed = true });
    const e_ca = try graph_core.createEdge(i32, testing.allocator, v_c, v_a, 0, .{ .directed = true });
    const e_de = try graph_core.createEdge(i32, testing.allocator, v_d, v_e, 0, .{ .directed = true });
    const e_ed = try graph_core.createEdge(i32, testing.allocator, v_e, v_d, 0, .{ .directed = true });
    const e_cf = try graph_core.createEdge(i32, testing.allocator, v_c, v_f, 0, .{ .directed = true });

    graph.addEdge(e_ab);
    graph.addEdge(e_bc);
    graph.addEdge(e_ca);
    graph.addEdge(e_de);
    graph.addEdge(e_ed);
    graph.addEdge(e_cf);

    var result = try connectivity.sccTarjan(i32, &graph, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.components.items.len);

    // First component should be {A, B, C}
    try testing.expectEqual(@as(usize, 3), result.components.items[0].items.len);
    try testing.expectEqualStrings("A", result.components.items[0].items[0]);
}

test "SCC Tarjan - single vertices" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v_a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v_b = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);

    graph.addVertex(v_a);
    graph.addVertex(v_b);

    const e_ab = try graph_core.createEdge(i32, testing.allocator, v_a, v_b, 0, .{ .directed = true });
    graph.addEdge(e_ab);

    var result = try connectivity.sccTarjan(i32, &graph, testing.allocator);
    defer result.deinit();

    // Each vertex is its own component
    try testing.expectEqual(@as(usize, 2), result.components.items.len);
}

test "Articulation Bridges - basic graph" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    // Graph shape: 1--2--3--4 and 2--5
    // Articulation points: 2, 3
    // Bridges: (1,2), (2,3), (2,5), (3,4)
    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "1", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "2", 2);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "3", 3);
    const v4 = try graph_core.Vertex(i32).initWithId(testing.allocator, "4", 4);
    const v5 = try graph_core.Vertex(i32).initWithId(testing.allocator, "5", 5);

    graph.addVertex(v1);
    graph.addVertex(v2);
    graph.addVertex(v3);
    graph.addVertex(v4);
    graph.addVertex(v5);

    const e12 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{});
    const e23 = try graph_core.createEdge(i32, testing.allocator, v2, v3, 0, .{});
    const e34 = try graph_core.createEdge(i32, testing.allocator, v3, v4, 0, .{});
    const e25 = try graph_core.createEdge(i32, testing.allocator, v2, v5, 0, .{});

    graph.addEdge(e12);
    graph.addEdge(e23);
    graph.addEdge(e34);
    graph.addEdge(e25);

    var result = try connectivity.articulationBridges(i32, &graph, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.points.items.len);
    try testing.expectEqualStrings("2", result.points.items[0]);
    try testing.expectEqualStrings("3", result.points.items[1]);

    try testing.expectEqual(@as(usize, 4), result.bridges.items.len);
}

test "Articulation Bridges - triangle with no bridges" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    // Triangle: 1--2--3--1 (no articulation points or bridges)
    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "1", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "2", 2);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "3", 3);

    graph.addVertex(v1);
    graph.addVertex(v2);
    graph.addVertex(v3);

    const e12 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{});
    const e23 = try graph_core.createEdge(i32, testing.allocator, v2, v3, 0, .{});
    const e31 = try graph_core.createEdge(i32, testing.allocator, v3, v1, 0, .{});

    graph.addEdge(e12);
    graph.addEdge(e23);
    graph.addEdge(e31);

    var result = try connectivity.articulationBridges(i32, &graph, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.points.items.len);
    try testing.expectEqual(@as(usize, 0), result.bridges.items.len);
}

test "Articulation Bridges - single edge" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);

    graph.addVertex(v1);
    graph.addVertex(v2);

    const e = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{});
    graph.addEdge(e);

    var result = try connectivity.articulationBridges(i32, &graph, testing.allocator);
    defer result.deinit();

    // Single edge is a bridge, but endpoints are not articulation points
    try testing.expectEqual(@as(usize, 0), result.points.items.len);
    try testing.expectEqual(@as(usize, 1), result.bridges.items.len);
}

test "Articulation Bridges - star graph" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    // Star: center connected to 4 leaves
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

    var result = try connectivity.articulationBridges(i32, &graph, testing.allocator);
    defer result.deinit();

    // Center is an articulation point, all edges are bridges
    try testing.expectEqual(@as(usize, 1), result.points.items.len);
    try testing.expectEqualStrings("C", result.points.items[0]);
    try testing.expectEqual(@as(usize, 4), result.bridges.items.len);
}
