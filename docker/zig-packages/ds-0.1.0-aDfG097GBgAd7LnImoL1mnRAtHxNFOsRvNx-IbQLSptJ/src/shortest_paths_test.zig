// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;
const Graph = @import("graph.zig").Graph;
const graph_core = @import("graph_core.zig");
const sp = @import("shortest_paths.zig");

test "Dijkstra - simple path" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    graph.addVertex(v1);
    graph.addVertex(v2);
    graph.addVertex(v3);

    const e1 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 1.0,
    });
    const e2 = try graph_core.createEdge(i32, testing.allocator, v2, v3, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 2.0,
    });

    graph.addEdge(e1);
    graph.addEdge(e2);

    var path = try sp.dijkstra(i32, &graph, v1, v3, testing.allocator);
    defer path.deinit();

    try testing.expect(!path.isEmpty());
    try testing.expectEqual(@as(usize, 3), path.nodes.items.len);
    try testing.expectEqualStrings("A", path.nodes.items[0]);
    try testing.expectEqualStrings("B", path.nodes.items[1]);
    try testing.expectEqualStrings("C", path.nodes.items[2]);
    try testing.expectEqual(@as(f64, 3.0), path.cost);
}

test "Dijkstra - no path" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);

    graph.addVertex(v1);
    graph.addVertex(v2);

    var path = try sp.dijkstra(i32, &graph, v1, v2, testing.allocator);
    defer path.deinit();

    try testing.expect(path.isEmpty());
}

test "Dijkstra - weighted undirected" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    graph.addVertex(v1);
    graph.addVertex(v2);
    graph.addVertex(v3);

    const e1 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{
        .weighted = true,
        .weight = 5.0,
    });
    const e2 = try graph_core.createEdge(i32, testing.allocator, v1, v3, 0, .{
        .weighted = true,
        .weight = 2.0,
    });
    const e3 = try graph_core.createEdge(i32, testing.allocator, v3, v2, 0, .{
        .weighted = true,
        .weight = 1.0,
    });

    graph.addEdge(e1);
    graph.addEdge(e2);
    graph.addEdge(e3);

    var path = try sp.dijkstra(i32, &graph, v1, v2, testing.allocator);
    defer path.deinit();

    try testing.expect(!path.isEmpty());
    try testing.expectEqual(@as(f64, 3.0), path.cost); // A -> C -> B = 2 + 1
    try testing.expectEqual(@as(usize, 3), path.nodes.items.len);
    try testing.expectEqualStrings("A", path.nodes.items[0]);
    try testing.expectEqualStrings("C", path.nodes.items[1]);
    try testing.expectEqualStrings("B", path.nodes.items[2]);
}

fn euclideanHeuristic(a: *graph_core.Vertex(i32), b: *graph_core.Vertex(i32)) f64 {
    // Simple heuristic for testing (always returns 0, making it equivalent to Dijkstra)
    _ = a;
    _ = b;
    return 0.0;
}

test "A* - simple path" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    graph.addVertex(v1);
    graph.addVertex(v2);
    graph.addVertex(v3);

    const e1 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 1.0,
    });
    const e2 = try graph_core.createEdge(i32, testing.allocator, v2, v3, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 2.0,
    });

    graph.addEdge(e1);
    graph.addEdge(e2);

    var path = try sp.aStar(i32, &graph, v1, v3, euclideanHeuristic, testing.allocator);
    defer path.deinit();

    try testing.expect(!path.isEmpty());
    try testing.expectEqual(@as(usize, 3), path.nodes.items.len);
    try testing.expectEqual(@as(f64, 3.0), path.cost);
}

test "A* - same source and destination" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    graph.addVertex(v1);

    var path = try sp.aStar(i32, &graph, v1, v1, euclideanHeuristic, testing.allocator);
    defer path.deinit();

    try testing.expectEqual(@as(usize, 1), path.nodes.items.len);
    try testing.expectEqualStrings("A", path.nodes.items[0]);
    try testing.expectEqual(@as(f64, 0.0), path.cost);
}

test "IDDFS - finds path" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    graph.addVertex(v1);
    graph.addVertex(v2);
    graph.addVertex(v3);

    const e1 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{ .directed = true });
    const e2 = try graph_core.createEdge(i32, testing.allocator, v2, v3, 0, .{ .directed = true });

    graph.addEdge(e1);
    graph.addEdge(e2);

    var path = try sp.iddfs(i32, &graph, v1, "C", 10, testing.allocator);
    defer path.deinit();

    try testing.expect(!path.isEmpty());
    try testing.expectEqualStrings("A", path.nodes.items[0]);
    try testing.expectEqualStrings("C", path.nodes.items[path.nodes.items.len - 1]);
}

test "IDDFS - depth limit" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    graph.addVertex(v1);
    graph.addVertex(v2);
    graph.addVertex(v3);

    const e1 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{ .directed = true });
    const e2 = try graph_core.createEdge(i32, testing.allocator, v2, v3, 0, .{ .directed = true });

    graph.addEdge(e1);
    graph.addEdge(e2);

    // Depth limit of 1 should not reach C
    var path = try sp.iddfs(i32, &graph, v1, "C", 1, testing.allocator);
    defer path.deinit();

    try testing.expect(path.isEmpty());
}

test "DAG shortest path - simple" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    graph.addVertex(v1);
    graph.addVertex(v2);
    graph.addVertex(v3);

    const e1 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 5.0,
    });
    const e2 = try graph_core.createEdge(i32, testing.allocator, v1, v3, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 2.0,
    });
    const e3 = try graph_core.createEdge(i32, testing.allocator, v3, v2, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 1.0,
    });

    graph.addEdge(e1);
    graph.addEdge(e2);
    graph.addEdge(e3);

    var path = try sp.dagShortestPath(i32, &graph, v1, v2, testing.allocator);
    defer path.deinit();

    try testing.expect(!path.isEmpty());
    try testing.expectEqual(@as(f64, 3.0), path.cost); // A -> C -> B = 2 + 1
    try testing.expectEqual(@as(usize, 3), path.nodes.items.len);
}

test "DAG shortest path - cyclic graph" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);

    graph.addVertex(v1);
    graph.addVertex(v2);

    const e1 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{ .directed = true });
    const e2 = try graph_core.createEdge(i32, testing.allocator, v2, v1, 0, .{ .directed = true });

    graph.addEdge(e1);
    graph.addEdge(e2);

    var path = try sp.dagShortestPath(i32, &graph, v1, v2, testing.allocator);
    defer path.deinit();

    // Should return empty path for cyclic graph
    try testing.expect(path.isEmpty());
}
