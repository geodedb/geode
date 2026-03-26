// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;
const Graph = @import("graph.zig").Graph;
const graph_core = @import("graph_core.zig");
const sp = @import("shortest_paths.zig");
const app = @import("all_pairs_paths.zig");

test "Dijkstra - simple path" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const v1 = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const v2 = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const v3 = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    try graph.addVertex(v1);
    try graph.addVertex(v2);
    try graph.addVertex(v3);

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

    try graph.addEdge(e1);
    try graph.addEdge(e2);

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

    try graph.addVertex(v1);
    try graph.addVertex(v2);

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

    try graph.addVertex(v1);
    try graph.addVertex(v2);
    try graph.addVertex(v3);

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

    try graph.addEdge(e1);
    try graph.addEdge(e2);
    try graph.addEdge(e3);

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

    try graph.addVertex(v1);
    try graph.addVertex(v2);
    try graph.addVertex(v3);

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

    try graph.addEdge(e1);
    try graph.addEdge(e2);

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
    try graph.addVertex(v1);

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

    try graph.addVertex(v1);
    try graph.addVertex(v2);
    try graph.addVertex(v3);

    const e1 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{ .directed = true });
    const e2 = try graph_core.createEdge(i32, testing.allocator, v2, v3, 0, .{ .directed = true });

    try graph.addEdge(e1);
    try graph.addEdge(e2);

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

    try graph.addVertex(v1);
    try graph.addVertex(v2);
    try graph.addVertex(v3);

    const e1 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{ .directed = true });
    const e2 = try graph_core.createEdge(i32, testing.allocator, v2, v3, 0, .{ .directed = true });

    try graph.addEdge(e1);
    try graph.addEdge(e2);

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

    try graph.addVertex(v1);
    try graph.addVertex(v2);
    try graph.addVertex(v3);

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

    try graph.addEdge(e1);
    try graph.addEdge(e2);
    try graph.addEdge(e3);

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

    try graph.addVertex(v1);
    try graph.addVertex(v2);

    const e1 = try graph_core.createEdge(i32, testing.allocator, v1, v2, 0, .{ .directed = true });
    const e2 = try graph_core.createEdge(i32, testing.allocator, v2, v1, 0, .{ .directed = true });

    try graph.addEdge(e1);
    try graph.addEdge(e2);

    var path = try sp.dagShortestPath(i32, &graph, v1, v2, testing.allocator);
    defer path.deinit();

    // Should return empty path for cyclic graph
    try testing.expect(path.isEmpty());
}

// ============================================================================
// Bellman-Ford Tests
// ============================================================================

test "BellmanFord - basic positive weights matches Dijkstra" {
    // Graph: A -1-> B -2-> C, A -10-> C
    // Shortest: A -> B -> C = 3.0
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const va = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const vb = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const vc = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    try graph.addVertex(va);
    try graph.addVertex(vb);
    try graph.addVertex(vc);

    const e1 = try graph_core.createEdge(i32, testing.allocator, va, vb, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 1.0,
    });
    const e2 = try graph_core.createEdge(i32, testing.allocator, vb, vc, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 2.0,
    });
    const e3 = try graph_core.createEdge(i32, testing.allocator, va, vc, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 10.0,
    });

    try graph.addEdge(e1);
    try graph.addEdge(e2);
    try graph.addEdge(e3);

    // Run Bellman-Ford from A
    var bf = try app.bellmanFord(i32, &graph, va, testing.allocator);
    defer bf.deinit();

    try testing.expect(!bf.has_negative_cycle);

    // Distance to A should be 0
    try testing.expectEqual(@as(f64, 0.0), bf.distances.get("A").?);
    // Distance to B should be 1
    try testing.expectEqual(@as(f64, 1.0), bf.distances.get("B").?);
    // Distance to C should be 3 (A->B->C), not 10 (A->C)
    try testing.expectEqual(@as(f64, 3.0), bf.distances.get("C").?);

    // Verify path reconstruction matches Dijkstra result
    var bf_path = try bf.getPath("A", "C");
    defer bf_path.deinit();

    try testing.expect(!bf_path.isEmpty());
    try testing.expectEqual(@as(f64, 3.0), bf_path.cost);
    try testing.expectEqual(@as(usize, 3), bf_path.nodes.items.len);
    try testing.expectEqualStrings("A", bf_path.nodes.items[0]);
    try testing.expectEqualStrings("B", bf_path.nodes.items[1]);
    try testing.expectEqualStrings("C", bf_path.nodes.items[2]);

    // Compare with Dijkstra
    var dijk_path = try sp.dijkstra(i32, &graph, va, vc, testing.allocator);
    defer dijk_path.deinit();

    try testing.expectEqual(dijk_path.cost, bf_path.cost);
}

test "BellmanFord - negative edge weights" {
    // Graph: A -4-> B -(-2)-> C -3-> D
    //        A -5-> D (direct, longer)
    // Shortest A->D: A->B->C->D = 4 + (-2) + 3 = 5
    // But direct A->D = 5 also. Both equal here.
    // Shortest A->C: A->B->C = 4 + (-2) = 2
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const va = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const vb = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const vc = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);
    const vd = try graph_core.Vertex(i32).initWithId(testing.allocator, "D", 4);

    try graph.addVertex(va);
    try graph.addVertex(vb);
    try graph.addVertex(vc);
    try graph.addVertex(vd);

    const e1 = try graph_core.createEdge(i32, testing.allocator, va, vb, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 4.0,
    });
    const e2 = try graph_core.createEdge(i32, testing.allocator, vb, vc, 0, .{
        .directed = true,
        .weighted = true,
        .weight = -2.0,
    });
    const e3 = try graph_core.createEdge(i32, testing.allocator, vc, vd, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 3.0,
    });
    const e4 = try graph_core.createEdge(i32, testing.allocator, va, vd, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 8.0,
    });

    try graph.addEdge(e1);
    try graph.addEdge(e2);
    try graph.addEdge(e3);
    try graph.addEdge(e4);

    var bf = try app.bellmanFord(i32, &graph, va, testing.allocator);
    defer bf.deinit();

    try testing.expect(!bf.has_negative_cycle);

    // A->B = 4
    try testing.expectEqual(@as(f64, 4.0), bf.distances.get("B").?);
    // A->C = 4 + (-2) = 2
    try testing.expectEqual(@as(f64, 2.0), bf.distances.get("C").?);
    // A->D = 4 + (-2) + 3 = 5, which is shorter than 8
    try testing.expectEqual(@as(f64, 5.0), bf.distances.get("D").?);
}

test "BellmanFord - negative cycle detection" {
    // Graph: A -1-> B -1-> C -(-5)-> A
    // This forms a negative cycle: 1 + 1 + (-5) = -3
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const va = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const vb = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const vc = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    try graph.addVertex(va);
    try graph.addVertex(vb);
    try graph.addVertex(vc);

    const e1 = try graph_core.createEdge(i32, testing.allocator, va, vb, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 1.0,
    });
    const e2 = try graph_core.createEdge(i32, testing.allocator, vb, vc, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 1.0,
    });
    const e3 = try graph_core.createEdge(i32, testing.allocator, vc, va, 0, .{
        .directed = true,
        .weighted = true,
        .weight = -5.0,
    });

    try graph.addEdge(e1);
    try graph.addEdge(e2);
    try graph.addEdge(e3);

    var bf = try app.bellmanFord(i32, &graph, va, testing.allocator);
    defer bf.deinit();

    try testing.expect(bf.has_negative_cycle);
}

test "BellmanFord - single node graph" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const va = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    try graph.addVertex(va);

    var bf = try app.bellmanFord(i32, &graph, va, testing.allocator);
    defer bf.deinit();

    try testing.expect(!bf.has_negative_cycle);
    try testing.expectEqual(@as(f64, 0.0), bf.distances.get("A").?);
}

test "BellmanFord - unreachable vertex" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const va = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const vb = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);

    try graph.addVertex(va);
    try graph.addVertex(vb);

    // No edges: B is unreachable from A
    var bf = try app.bellmanFord(i32, &graph, va, testing.allocator);
    defer bf.deinit();

    try testing.expect(!bf.has_negative_cycle);
    try testing.expectEqual(@as(f64, 0.0), bf.distances.get("A").?);
    try testing.expect(std.math.isInf(bf.distances.get("B").?));

    // Path to B should be empty
    var path = try bf.getPath("A", "B");
    defer path.deinit();

    try testing.expect(path.isEmpty());
}

// ============================================================================
// Floyd-Warshall Tests
// ============================================================================

test "FloydWarshall - basic all-pairs shortest paths" {
    // Graph: A -3-> B -1-> C, A -10-> C
    // Shortest A->C: A->B->C = 4
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const va = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const vb = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const vc = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    try graph.addVertex(va);
    try graph.addVertex(vb);
    try graph.addVertex(vc);

    const e1 = try graph_core.createEdge(i32, testing.allocator, va, vb, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 3.0,
    });
    const e2 = try graph_core.createEdge(i32, testing.allocator, vb, vc, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 1.0,
    });
    const e3 = try graph_core.createEdge(i32, testing.allocator, va, vc, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 10.0,
    });

    try graph.addEdge(e1);
    try graph.addEdge(e2);
    try graph.addEdge(e3);

    var fw = try app.floydWarshall(i32, &graph, testing.allocator);
    defer fw.deinit();

    try testing.expect(!fw.has_negative_cycle);

    // Self-distances should be 0
    try testing.expectEqual(@as(f64, 0.0), (try fw.getDistance("A", "A")).?);
    try testing.expectEqual(@as(f64, 0.0), (try fw.getDistance("B", "B")).?);
    try testing.expectEqual(@as(f64, 0.0), (try fw.getDistance("C", "C")).?);

    // A->B = 3
    try testing.expectEqual(@as(f64, 3.0), (try fw.getDistance("A", "B")).?);
    // A->C = min(10, 3+1) = 4
    try testing.expectEqual(@as(f64, 4.0), (try fw.getDistance("A", "C")).?);
    // B->C = 1
    try testing.expectEqual(@as(f64, 1.0), (try fw.getDistance("B", "C")).?);

    // No edge from C to A/B, should be infinity
    try testing.expect(std.math.isInf((try fw.getDistance("C", "A")).?));
    try testing.expect(std.math.isInf((try fw.getDistance("C", "B")).?));
}

test "FloydWarshall - matches Dijkstra for positive weights" {
    // Diamond graph: A->B(1), A->C(5), B->D(3), C->D(1)
    // Shortest A->D: A->B->D = 4 or A->C->D = 6, so 4
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const va = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const vb = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const vc = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);
    const vd = try graph_core.Vertex(i32).initWithId(testing.allocator, "D", 4);

    try graph.addVertex(va);
    try graph.addVertex(vb);
    try graph.addVertex(vc);
    try graph.addVertex(vd);

    const e1 = try graph_core.createEdge(i32, testing.allocator, va, vb, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 1.0,
    });
    const e2 = try graph_core.createEdge(i32, testing.allocator, va, vc, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 5.0,
    });
    const e3 = try graph_core.createEdge(i32, testing.allocator, vb, vd, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 3.0,
    });
    const e4 = try graph_core.createEdge(i32, testing.allocator, vc, vd, 0, .{
        .directed = true,
        .weighted = true,
        .weight = 1.0,
    });

    try graph.addEdge(e1);
    try graph.addEdge(e2);
    try graph.addEdge(e3);
    try graph.addEdge(e4);

    // Floyd-Warshall
    var fw = try app.floydWarshall(i32, &graph, testing.allocator);
    defer fw.deinit();

    // Dijkstra A->D
    var dijk_path = try sp.dijkstra(i32, &graph, va, vd, testing.allocator);
    defer dijk_path.deinit();

    const fw_dist_ad = (try fw.getDistance("A", "D")).?;
    try testing.expectEqual(dijk_path.cost, fw_dist_ad);
    try testing.expectEqual(@as(f64, 4.0), fw_dist_ad);

    // Dijkstra A->B
    var dijk_ab = try sp.dijkstra(i32, &graph, va, vb, testing.allocator);
    defer dijk_ab.deinit();

    const fw_dist_ab = (try fw.getDistance("A", "B")).?;
    try testing.expectEqual(dijk_ab.cost, fw_dist_ab);
}

test "FloydWarshall - isolated vertices (no edges)" {
    var graph = Graph(i32).init(testing.allocator);
    defer graph.deinit();

    const va = try graph_core.Vertex(i32).initWithId(testing.allocator, "A", 1);
    const vb = try graph_core.Vertex(i32).initWithId(testing.allocator, "B", 2);
    const vc = try graph_core.Vertex(i32).initWithId(testing.allocator, "C", 3);

    try graph.addVertex(va);
    try graph.addVertex(vb);
    try graph.addVertex(vc);

    // No edges added
    var fw = try app.floydWarshall(i32, &graph, testing.allocator);
    defer fw.deinit();

    try testing.expect(!fw.has_negative_cycle);

    // Self-distances should be 0
    try testing.expectEqual(@as(f64, 0.0), (try fw.getDistance("A", "A")).?);
    try testing.expectEqual(@as(f64, 0.0), (try fw.getDistance("B", "B")).?);
    try testing.expectEqual(@as(f64, 0.0), (try fw.getDistance("C", "C")).?);

    // All cross-distances should be infinity
    try testing.expect(std.math.isInf((try fw.getDistance("A", "B")).?));
    try testing.expect(std.math.isInf((try fw.getDistance("A", "C")).?));
    try testing.expect(std.math.isInf((try fw.getDistance("B", "A")).?));
    try testing.expect(std.math.isInf((try fw.getDistance("B", "C")).?));
    try testing.expect(std.math.isInf((try fw.getDistance("C", "A")).?));
    try testing.expect(std.math.isInf((try fw.getDistance("C", "B")).?));
}
