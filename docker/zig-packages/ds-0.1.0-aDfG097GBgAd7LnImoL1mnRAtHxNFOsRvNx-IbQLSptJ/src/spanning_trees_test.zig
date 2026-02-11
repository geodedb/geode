// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;
const Graph = @import("graph.zig").Graph;
const graph_core = @import("graph_core.zig");
const spanning_trees = @import("spanning_trees.zig");

test "Kruskal MST - basic graph" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    // Graph: A-B(1), A-C(4), B-C(2), B-D(5), C-D(1)
    // MST should pick: A-B(1), C-D(1), B-C(2) = total weight 4
    const v_a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v_b = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v_c = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);
    const v_d = try graph_core.Vertex(i32).initWithId(testing.allocator, "D", 4);

    graph.addVertex(v_a);
    graph.addVertex(v_b);
    graph.addVertex(v_c);
    graph.addVertex(v_d);

    const e_ab = try graph_core.createEdge(i32, testing.allocator, v_a, v_b, 0, .{
        .weighted = true,
        .weight = 1.0,
    });
    const e_ac = try graph_core.createEdge(i32, testing.allocator, v_a, v_c, 0, .{
        .weighted = true,
        .weight = 4.0,
    });
    const e_bc = try graph_core.createEdge(i32, testing.allocator, v_b, v_c, 0, .{
        .weighted = true,
        .weight = 2.0,
    });
    const e_bd = try graph_core.createEdge(i32, testing.allocator, v_b, v_d, 0, .{
        .weighted = true,
        .weight = 5.0,
    });
    const e_cd = try graph_core.createEdge(i32, testing.allocator, v_c, v_d, 0, .{
        .weighted = true,
        .weight = 1.0,
    });

    graph.addEdge(e_ab);
    graph.addEdge(e_ac);
    graph.addEdge(e_bc);
    graph.addEdge(e_bd);
    graph.addEdge(e_cd);

    var mst = try spanning_trees.kruskal(i32, &graph, testing.allocator);
    defer mst.deinit();

    try testing.expectEqual(@as(usize, 3), mst.edges.items.len);
    try testing.expectEqual(@as(f64, 4.0), mst.total_weight);
}

test "Kruskal MST - unweighted edges" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v_a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v_b = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v_c = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    graph.addVertex(v_a);
    graph.addVertex(v_b);
    graph.addVertex(v_c);

    const e_ab = try graph_core.createEdge(i32, testing.allocator, v_a, v_b, 0, .{});
    const e_bc = try graph_core.createEdge(i32, testing.allocator, v_b, v_c, 0, .{});
    const e_ac = try graph_core.createEdge(i32, testing.allocator, v_a, v_c, 0, .{});

    graph.addEdge(e_ab);
    graph.addEdge(e_bc);
    graph.addEdge(e_ac);

    var mst = try spanning_trees.kruskal(i32, &graph, testing.allocator);
    defer mst.deinit();

    // For triangle with unweighted edges, MST has 2 edges with total weight 2.0
    try testing.expectEqual(@as(usize, 2), mst.edges.items.len);
    try testing.expectEqual(@as(f64, 2.0), mst.total_weight);
}

test "Kruskal MST - single vertex" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v_a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    graph.addVertex(v_a);

    var mst = try spanning_trees.kruskal(i32, &graph, testing.allocator);
    defer mst.deinit();

    try testing.expectEqual(@as(usize, 0), mst.edges.items.len);
    try testing.expectEqual(@as(f64, 0.0), mst.total_weight);
}

test "Kruskal MST - disconnected graph" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v_a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v_b = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v_c = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);
    const v_d = try graph_core.Vertex(i32).initWithId(testing.allocator, "D", 4);

    graph.addVertex(v_a);
    graph.addVertex(v_b);
    graph.addVertex(v_c);
    graph.addVertex(v_d);

    // Two components: A-B and C-D
    const e_ab = try graph_core.createEdge(i32, testing.allocator, v_a, v_b, 0, .{
        .weighted = true,
        .weight = 1.0,
    });
    const e_cd = try graph_core.createEdge(i32, testing.allocator, v_c, v_d, 0, .{
        .weighted = true,
        .weight = 2.0,
    });

    graph.addEdge(e_ab);
    graph.addEdge(e_cd);

    var mst = try spanning_trees.kruskal(i32, &graph, testing.allocator);
    defer mst.deinit();

    // MST for forest: one edge per component
    try testing.expectEqual(@as(usize, 2), mst.edges.items.len);
    try testing.expectEqual(@as(f64, 3.0), mst.total_weight);
}

test "Prim MST - basic graph" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    // Same graph as Kruskal test
    const v_a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v_b = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v_c = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);
    const v_d = try graph_core.Vertex(i32).initWithId(testing.allocator, "D", 4);

    graph.addVertex(v_a);
    graph.addVertex(v_b);
    graph.addVertex(v_c);
    graph.addVertex(v_d);

    const e_ab = try graph_core.createEdge(i32, testing.allocator, v_a, v_b, 0, .{
        .weighted = true,
        .weight = 1.0,
    });
    const e_ac = try graph_core.createEdge(i32, testing.allocator, v_a, v_c, 0, .{
        .weighted = true,
        .weight = 4.0,
    });
    const e_bc = try graph_core.createEdge(i32, testing.allocator, v_b, v_c, 0, .{
        .weighted = true,
        .weight = 2.0,
    });
    const e_bd = try graph_core.createEdge(i32, testing.allocator, v_b, v_d, 0, .{
        .weighted = true,
        .weight = 5.0,
    });
    const e_cd = try graph_core.createEdge(i32, testing.allocator, v_c, v_d, 0, .{
        .weighted = true,
        .weight = 1.0,
    });

    graph.addEdge(e_ab);
    graph.addEdge(e_ac);
    graph.addEdge(e_bc);
    graph.addEdge(e_bd);
    graph.addEdge(e_cd);

    var mst = try spanning_trees.prim(i32, &graph, v_a, testing.allocator);
    defer mst.deinit();

    try testing.expectEqual(@as(usize, 3), mst.edges.items.len);
    try testing.expectEqual(@as(f64, 4.0), mst.total_weight);
}

test "Prim MST - single vertex" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v_a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    graph.addVertex(v_a);

    var mst = try spanning_trees.prim(i32, &graph, v_a, testing.allocator);
    defer mst.deinit();

    try testing.expectEqual(@as(usize, 0), mst.edges.items.len);
    try testing.expectEqual(@as(f64, 0.0), mst.total_weight);
}

test "Prim MST - linear chain" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v_a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v_b = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v_c = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    graph.addVertex(v_a);
    graph.addVertex(v_b);
    graph.addVertex(v_c);

    const e_ab = try graph_core.createEdge(i32, testing.allocator, v_a, v_b, 0, .{
        .weighted = true,
        .weight = 1.0,
    });
    const e_bc = try graph_core.createEdge(i32, testing.allocator, v_b, v_c, 0, .{
        .weighted = true,
        .weight = 2.0,
    });

    graph.addEdge(e_ab);
    graph.addEdge(e_bc);

    var mst = try spanning_trees.prim(i32, &graph, v_a, testing.allocator);
    defer mst.deinit();

    try testing.expectEqual(@as(usize, 2), mst.edges.items.len);
    try testing.expectEqual(@as(f64, 3.0), mst.total_weight);
}

test "Prim MST - directed edges treated as undirected" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v_a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v_b = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v_c = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    graph.addVertex(v_a);
    graph.addVertex(v_b);
    graph.addVertex(v_c);

    const e_ab = try graph_core.createEdge(i32, testing.allocator, v_a, v_b, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 1.0,
    });
    const e_bc = try graph_core.createEdge(i32, testing.allocator, v_b, v_c, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 2.0,
    });

    graph.addEdge(e_ab);
    graph.addEdge(e_bc);

    var mst = try spanning_trees.prim(i32, &graph, v_a, testing.allocator);
    defer mst.deinit();

    try testing.expectEqual(@as(usize, 2), mst.edges.items.len);
    try testing.expectEqual(@as(f64, 3.0), mst.total_weight);
}
