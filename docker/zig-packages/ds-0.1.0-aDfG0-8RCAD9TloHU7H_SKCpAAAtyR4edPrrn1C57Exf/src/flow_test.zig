// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;
const Graph = @import("graph.zig").Graph;
const graph_core = @import("graph_core.zig");
const flow = @import("flow.zig");

test "Edmonds-Karp - basic max flow" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    // Build standard max flow network
    // S -> A (10), S -> B (5)
    // A -> B (15), A -> C (10)
    // B -> C (10), B -> T (5)
    // C -> T (10)
    // Expected max flow: 15
    const s = try graph_core.Vertex(i32).initWithId(testing.allocator, "S", 0);
    const a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const b = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const c = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);
    const t = try graph_core.Vertex(i32).initWithId(testing.allocator, "T", 4);

    try graph.addVertex(s);
    try graph.addVertex(a);
    try graph.addVertex(b);
    try graph.addVertex(c);
    try graph.addVertex(t);

    const e_sa = try graph_core.createEdge(i32, testing.allocator, s, a, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 10.0,
    });
    const e_sb = try graph_core.createEdge(i32, testing.allocator, s, b, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 5.0,
    });
    const e_ab = try graph_core.createEdge(i32, testing.allocator, a, b, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 15.0,
    });
    const e_ac = try graph_core.createEdge(i32, testing.allocator, a, c, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 10.0,
    });
    const e_bc = try graph_core.createEdge(i32, testing.allocator, b, c, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 10.0,
    });
    const e_bt = try graph_core.createEdge(i32, testing.allocator, b, t, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 5.0,
    });
    const e_ct = try graph_core.createEdge(i32, testing.allocator, c, t, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 10.0,
    });

    try graph.addEdge(e_sa);
    try graph.addEdge(e_sb);
    try graph.addEdge(e_ab);
    try graph.addEdge(e_ac);
    try graph.addEdge(e_bc);
    try graph.addEdge(e_bt);
    try graph.addEdge(e_ct);

    var result = try flow.edmondsKarp(i32, &graph, s, t, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(f64, 15.0), result.flow);
}

test "Edmonds-Karp - same source and sink" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const s = try graph_core.Vertex(i32).initWithId(testing.allocator, "S", 0);
    try graph.addVertex(s);

    var result = try flow.edmondsKarp(i32, &graph, s, s, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(f64, 0.0), result.flow);
}

test "Edmonds-Karp - no path" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const s = try graph_core.Vertex(i32).initWithId(testing.allocator, "S", 0);
    const t = try graph_core.Vertex(i32).initWithId(testing.allocator, "T", 1);

    try graph.addVertex(s);
    try graph.addVertex(t);

    var result = try flow.edmondsKarp(i32, &graph, s, t, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(f64, 0.0), result.flow);
}

test "Edmonds-Karp - simple path" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const s = try graph_core.Vertex(i32).initWithId(testing.allocator, "S", 0);
    const t = try graph_core.Vertex(i32).initWithId(testing.allocator, "T", 1);

    try graph.addVertex(s);
    try graph.addVertex(t);

    const e = try graph_core.createEdge(i32, testing.allocator, s, t, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 10.0,
    });
    try graph.addEdge(e);

    var result = try flow.edmondsKarp(i32, &graph, s, t, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(f64, 10.0), result.flow);
}

test "Dinic - basic max flow" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    // Same network as Edmonds-Karp test
    const s = try graph_core.Vertex(i32).initWithId(testing.allocator, "S", 0);
    const a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const b = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const c = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);
    const t = try graph_core.Vertex(i32).initWithId(testing.allocator, "T", 4);

    try graph.addVertex(s);
    try graph.addVertex(a);
    try graph.addVertex(b);
    try graph.addVertex(c);
    try graph.addVertex(t);

    const e_sa = try graph_core.createEdge(i32, testing.allocator, s, a, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 10.0,
    });
    const e_sb = try graph_core.createEdge(i32, testing.allocator, s, b, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 5.0,
    });
    const e_ab = try graph_core.createEdge(i32, testing.allocator, a, b, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 15.0,
    });
    const e_ac = try graph_core.createEdge(i32, testing.allocator, a, c, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 10.0,
    });
    const e_bc = try graph_core.createEdge(i32, testing.allocator, b, c, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 10.0,
    });
    const e_bt = try graph_core.createEdge(i32, testing.allocator, b, t, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 5.0,
    });
    const e_ct = try graph_core.createEdge(i32, testing.allocator, c, t, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 10.0,
    });

    try graph.addEdge(e_sa);
    try graph.addEdge(e_sb);
    try graph.addEdge(e_ab);
    try graph.addEdge(e_ac);
    try graph.addEdge(e_bc);
    try graph.addEdge(e_bt);
    try graph.addEdge(e_ct);

    var result = try flow.dinic(i32, &graph, s, t, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(f64, 15.0), result.flow);
}

test "Dinic - matches Edmonds-Karp" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const s = try graph_core.Vertex(i32).initWithId(testing.allocator, "S", 0);
    const a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const b = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const c = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);
    const t = try graph_core.Vertex(i32).initWithId(testing.allocator, "T", 4);

    try graph.addVertex(s);
    try graph.addVertex(a);
    try graph.addVertex(b);
    try graph.addVertex(c);
    try graph.addVertex(t);

    const e_sa = try graph_core.createEdge(i32, testing.allocator, s, a, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 10.0,
    });
    const e_sb = try graph_core.createEdge(i32, testing.allocator, s, b, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 5.0,
    });
    const e_ab = try graph_core.createEdge(i32, testing.allocator, a, b, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 15.0,
    });
    const e_ac = try graph_core.createEdge(i32, testing.allocator, a, c, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 10.0,
    });
    const e_bc = try graph_core.createEdge(i32, testing.allocator, b, c, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 10.0,
    });
    const e_bt = try graph_core.createEdge(i32, testing.allocator, b, t, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 5.0,
    });
    const e_ct = try graph_core.createEdge(i32, testing.allocator, c, t, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 10.0,
    });

    try graph.addEdge(e_sa);
    try graph.addEdge(e_sb);
    try graph.addEdge(e_ab);
    try graph.addEdge(e_ac);
    try graph.addEdge(e_bc);
    try graph.addEdge(e_bt);
    try graph.addEdge(e_ct);

    var result_ek = try flow.edmondsKarp(i32, &graph, s, t, testing.allocator);
    defer result_ek.deinit();

    var result_dinic = try flow.dinic(i32, &graph, s, t, testing.allocator);
    defer result_dinic.deinit();

    try testing.expectEqual(result_ek.flow, result_dinic.flow);
}

test "Dinic - same source and sink" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const s = try graph_core.Vertex(i32).initWithId(testing.allocator, "S", 0);
    try graph.addVertex(s);

    var result = try flow.dinic(i32, &graph, s, s, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(f64, 0.0), result.flow);
}

test "Dinic - unweighted edges" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const s = try graph_core.Vertex(i32).initWithId(testing.allocator, "S", 0);
    const a = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const t = try graph_core.Vertex(i32).initWithId(testing.allocator, "T", 2);

    try graph.addVertex(s);
    try graph.addVertex(a);
    try graph.addVertex(t);

    // Unweighted edges have capacity 1
    const e_sa = try graph_core.createEdge(i32, testing.allocator, s, a, 0, .{ .directed = true });
    const e_at = try graph_core.createEdge(i32, testing.allocator, a, t, 0, .{ .directed = true });

    try graph.addEdge(e_sa);
    try graph.addEdge(e_at);

    var result = try flow.dinic(i32, &graph, s, t, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(f64, 1.0), result.flow);
}
