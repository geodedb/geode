// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;
const Graph = @import("graph.zig").Graph;
const graph_core = @import("graph_core.zig");
const algo = @import("graph_algorithms.zig");

test "BFS - basic traversal" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    graph.addVertex(v1);
    graph.addVertex(v2);
    graph.addVertex(v3);

    const e1 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{});
    const e2 = try graph_core.createEdge(i32, testing.allocator, v2, v3, 0, .{});

    graph.addEdge(e1);
    graph.addEdge(e2);

    var result = try algo.bfsFrom(i32, &graph, v1, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.order.items.len);
    try testing.expectEqualStrings("A", result.order.items[0]);
    try testing.expectEqualStrings("B", result.order.items[1]);
    try testing.expectEqualStrings("C", result.order.items[2]);
}

test "DFS - basic traversal" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    graph.addVertex(v1);
    graph.addVertex(v2);
    graph.addVertex(v3);

    const e1 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{});
    const e2 = try graph_core.createEdge(i32, testing.allocator, v2, v3, 0, .{});

    graph.addEdge(e1);
    graph.addEdge(e2);

    var result = try algo.dfsFrom(i32, &graph, v1, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.order.items.len);
    try testing.expectEqualStrings("A", result.order.items[0]);
}

test "TopoKahn - directed acyclic graph" {
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

    var result = try algo.topoKahn(i32, &graph, testing.allocator);
    defer result.deinit();

    try testing.expect(result.is_acyclic);
    try testing.expectEqual(@as(usize, 3), result.order.items.len);
    try testing.expectEqualStrings("A", result.order.items[0]);
    try testing.expectEqualStrings("B", result.order.items[1]);
    try testing.expectEqualStrings("C", result.order.items[2]);
}

test "TopoKahn - cycle detection" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    graph.addVertex(v1);
    graph.addVertex(v2);
    graph.addVertex(v3);

    // Create a cycle: A -> B -> C -> A
    const e1 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{ .directed = true });
    const e2 = try graph_core.createEdge(i32, testing.allocator, v2, v3, 0, .{ .directed = true });
    const e3 = try graph_core.createEdge(i32, testing.allocator, v3, v1, 0, .{ .directed = true });

    graph.addEdge(e1);
    graph.addEdge(e2);
    graph.addEdge(e3);

    var result = try algo.topoKahn(i32, &graph, testing.allocator);
    defer result.deinit();

    try testing.expect(!result.is_acyclic);
}

test "TopoDFS - directed acyclic graph" {
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

    var result = try algo.topoDFS(i32, &graph, testing.allocator);
    defer result.deinit();

    try testing.expect(result.is_acyclic);
    try testing.expectEqual(@as(usize, 3), result.order.items.len);
}

test "CycleDetectDirected - no cycle" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);

    graph.addVertex(v1);
    graph.addVertex(v2);

    const e1 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{ .directed = true });
    graph.addEdge(e1);

    const has_cycle = try algo.cycleDetectDirected(i32, &graph, testing.allocator);
    try testing.expect(!has_cycle);
}

test "CycleDetectDirected - with cycle" {
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

    const has_cycle = try algo.cycleDetectDirected(i32, &graph, testing.allocator);
    try testing.expect(has_cycle);
}

test "CycleDetectUndirected - no cycle" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    graph.addVertex(v1);
    graph.addVertex(v2);
    graph.addVertex(v3);

    const e1 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{});
    const e2 = try graph_core.createEdge(i32, testing.allocator, v2, v3, 0, .{});

    graph.addEdge(e1);
    graph.addEdge(e2);

    const has_cycle = try algo.cycleDetectUndirected(i32, &graph, testing.allocator);
    try testing.expect(!has_cycle);
}

test "CycleDetectUndirected - with cycle" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    graph.addVertex(v1);
    graph.addVertex(v2);
    graph.addVertex(v3);

    const e1 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{});
    const e2 = try graph_core.createEdge(i32, testing.allocator, v2, v3, 0, .{});
    const e3 = try graph_core.createEdge(i32, testing.allocator, v3, v1, 0, .{});

    graph.addEdge(e1);
    graph.addEdge(e2);
    graph.addEdge(e3);

    const has_cycle = try algo.cycleDetectUndirected(i32, &graph, testing.allocator);
    try testing.expect(has_cycle);
}

test "MultiSourceBFS - single source" {
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

    const sources = [_]*graph_core.Vertex(i32){v1};
    var dist = try algo.multiSourceBFS(i32, &graph, &sources, testing.allocator);
    defer dist.deinit();

    try testing.expectEqual(@as(?usize, 0), dist.get("A"));
    try testing.expectEqual(@as(?usize, 1), dist.get("B"));
    try testing.expectEqual(@as(?usize, 2), dist.get("C"));
}

test "MultiSourceBFS - multiple sources" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    graph.addVertex(v1);
    graph.addVertex(v2);
    graph.addVertex(v3);

    const e1 = try graph_core.createEdge(i32, testing.allocator, v1, v3, 0, .{ .directed = true });
    const e2 = try graph_core.createEdge(i32, testing.allocator, v2, v3, 0, .{ .directed = true });

    graph.addEdge(e1);
    graph.addEdge(e2);

    const sources = [_]*graph_core.Vertex(i32){ v1, v2 };
    var dist = try algo.multiSourceBFS(i32, &graph, &sources, testing.allocator);
    defer dist.deinit();

    try testing.expectEqual(@as(?usize, 0), dist.get("A"));
    try testing.expectEqual(@as(?usize, 0), dist.get("B"));
    try testing.expectEqual(@as(?usize, 1), dist.get("C"));
}
