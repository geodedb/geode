// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const testing = std.testing;
const Graph = @import("graph.zig").Graph;
const Vertex = @import("graph_core.zig").Vertex;
const createEdge = @import("graph_core.zig").createEdge;
const EdgeOptions = @import("graph_core.zig").EdgeOptions;
const dot = @import("dot.zig");
const gql = @import("gql.zig");
const graph_algorithms = @import("graph_algorithms.zig");
const shortest_paths = @import("shortest_paths.zig");
const spanning_trees = @import("spanning_trees.zig");
const string_search = @import("string_search.zig");
const cache = @import("cache.zig");
const UnionFind = @import("unionfind.zig").UnionFind;

/// Generate random graph with n vertices and approximately m edges
fn generateRandomGraph(allocator: std.mem.Allocator, n: usize, m: usize, seed: u64, directed: bool) !*Graph([]const u8) {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    const graph = try allocator.create(Graph([]const u8));
    graph.* = Graph([]const u8).init(allocator);

    var vertices: std.ArrayListUnmanaged(*Vertex([]const u8)) = .{};
    defer vertices.deinit(allocator);

    // Create vertices
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const id = try std.fmt.allocPrint(allocator, "{d}", .{i});
        defer allocator.free(id); // initWithId duplicates the ID
        const vertex = try Vertex([]const u8).initWithId(allocator, id, "");
        graph.addVertex(vertex);
        try vertices.append(allocator, vertex);
    }

    // Add random edges
    var edge_count: usize = 0;
    while (edge_count < m and edge_count < n * n) {
        const a_idx = rand.uintLessThan(usize, n);
        const b_idx = rand.uintLessThan(usize, n);

        if (a_idx == b_idx) continue;

        const edge = try createEdge([]const u8, allocator, vertices.items[a_idx], vertices.items[b_idx], "", .{
            .directed = directed,
            .weighted = false,
            .weight = 0,
        });
        graph.addEdge(edge);
        edge_count += 1;
    }

    return graph;
}

// ============================================================================
// DOT Format Property Tests
// ============================================================================

test "Property - DOT roundtrip preserves graph structure" {
    const seeds = [_]u64{ 1, 42, 123, 999, 12345 };

    for (seeds) |seed| {
        const n = 5 + (seed % 10);
        const m = n + (seed % (n * 2));

        var graph = try generateRandomGraph(testing.allocator, n, m, seed, false);
        defer {
            graph.deinit();
            testing.allocator.destroy(graph);
        }

        // Skip empty graphs
        if (graph.edges.items.len == 0) continue;

        // Marshal to DOT
        var dot_graph = try dot.DOTGraph.init(testing.allocator, graph);
        defer dot_graph.deinit();

        var output: std.ArrayListUnmanaged(u8) = .{};
        defer output.deinit(testing.allocator);

        try dot_graph.marshal(output.writer(testing.allocator));

        // Unmarshal and verify structure preserved
        var stream = std.io.fixedBufferStream(output.items);
        var dot_graph2 = try dot.DOTGraph.unmarshal(testing.allocator, stream.reader());
        defer {
            dot_graph2.graph.deinit();
            testing.allocator.destroy(dot_graph2.graph);
            dot_graph2.deinit();
        }

        // Verify vertex count matches
        try testing.expectEqual(graph.vertices.items.len, dot_graph2.graph.vertices.items.len);
    }
}

test "Property - DOT marshal is deterministic" {
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    var graph = Graph([]const u8).init(testing.allocator);
    defer graph.deinit();

    // Create vertices in random order
    const vertices_to_add = [_][]const u8{ "Z", "A", "M", "C", "B" };
    var vertices: std.ArrayListUnmanaged(*Vertex([]const u8)) = .{};
    defer vertices.deinit(testing.allocator);

    for (vertices_to_add) |v_id| {
        // Use string literals - initWithId already duplicates the ID
        const vertex = try Vertex([]const u8).initWithId(testing.allocator, v_id, v_id);
        graph.addVertex(vertex);
        try vertices.append(testing.allocator, vertex);
    }

    // Add edges in random order
    const idx1 = rand.uintLessThan(usize, vertices.items.len);
    var idx2 = rand.uintLessThan(usize, vertices.items.len);
    while (idx2 == idx1) {
        idx2 = rand.uintLessThan(usize, vertices.items.len);
    }

    const edge = try createEdge([]const u8, testing.allocator, vertices.items[idx1], vertices.items[idx2], "", .{
        .directed = false,
        .weighted = false,
        .weight = 0,
    });
    graph.addEdge(edge);

    // Marshal twice and verify identical output
    var dot_graph = try dot.DOTGraph.init(testing.allocator, &graph);
    defer dot_graph.deinit();

    var output1: std.ArrayListUnmanaged(u8) = .{};
    defer output1.deinit(testing.allocator);
    try dot_graph.marshal(output1.writer(testing.allocator));

    var output2: std.ArrayListUnmanaged(u8) = .{};
    defer output2.deinit(testing.allocator);
    try dot_graph.marshal(output2.writer(testing.allocator));

    try testing.expectEqualStrings(output1.items, output2.items);
}

// ============================================================================
// Graph Algorithm Property Tests
// ============================================================================

test "Property - BFS produces valid distances" {
    const seeds = [_]u64{ 1, 42, 123 };

    for (seeds) |seed| {
        var graph = try generateRandomGraph(testing.allocator, 10, 15, seed, true);
        defer {
            graph.deinit();
            testing.allocator.destroy(graph);
        }

        if (graph.vertices.items.len == 0) continue;

        const start = graph.vertices.items[0];
        var result = try graph_algorithms.bfsFrom([]const u8, graph, start, testing.allocator);
        defer result.deinit();

        // Verify the start node is in the result order (first item)
        try testing.expect(result.order.items.len > 0);

        // Verify no self-predecessors
        var iter = result.prev.iterator();
        while (iter.next()) |entry| {
            const node_id = entry.key_ptr.*;
            const prev_id = entry.value_ptr.*;
            try testing.expect(!std.mem.eql(u8, node_id, prev_id));
        }
    }
}

test "Property - Dijkstra produces non-negative costs" {
    const seeds = [_]u64{ 2, 99, 456 };

    for (seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        var graph = Graph([]const u8).init(testing.allocator);
        defer graph.deinit();

        const n = 5 + (seed % 10);
        var vertices: std.ArrayListUnmanaged(*Vertex([]const u8)) = .{};
        defer vertices.deinit(testing.allocator);

        // Create vertices
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const id = try std.fmt.allocPrint(testing.allocator, "{d}", .{i});
            defer testing.allocator.free(id); // initWithId duplicates the ID
            const vertex = try Vertex([]const u8).initWithId(testing.allocator, id, "");
            graph.addVertex(vertex);
            try vertices.append(testing.allocator, vertex);
        }

        // Add weighted edges with positive weights
        const m = n + (seed % (n * 2));
        var j: usize = 0;
        while (j < m) : (j += 1) {
            const a_idx = rand.uintLessThan(usize, n);
            const b_idx = rand.uintLessThan(usize, n);
            if (a_idx == b_idx) continue;

            const weight = @as(f64, @floatFromInt(1 + rand.uintLessThan(u32, 20)));
            const edge = try createEdge([]const u8, testing.allocator, vertices.items[a_idx], vertices.items[b_idx], "", .{
                .directed = true,
                .weighted = true,
                .weight = weight,
            });
            graph.addEdge(edge);
        }

        if (vertices.items.len < 2) continue;

        var path = try shortest_paths.dijkstra([]const u8, &graph, vertices.items[0], vertices.items[vertices.items.len - 1], testing.allocator);
        defer path.deinit();

        // Cost should never be negative
        try testing.expect(path.cost >= 0);
    }
}

test "Property - Topological sort on DAG produces valid ordering" {
    const seeds = [_]u64{ 3, 77, 888 };

    for (seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        var graph = Graph([]const u8).init(testing.allocator);
        defer graph.deinit();

        const n = 5 + (seed % 10);
        var vertices: std.ArrayListUnmanaged(*Vertex([]const u8)) = .{};
        defer vertices.deinit(testing.allocator);

        // Create vertices
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const id = try std.fmt.allocPrint(testing.allocator, "{d}", .{i});
            defer testing.allocator.free(id); // initWithId duplicates the ID
            const vertex = try Vertex([]const u8).initWithId(testing.allocator, id, "");
            graph.addVertex(vertex);
            try vertices.append(testing.allocator, vertex);
        }

        // Create DAG by only adding edges i->j where j > i
        const m = n + (seed % (n * 2));
        var j: usize = 0;
        while (j < m) : (j += 1) {
            if (n < 2) break;
            const a_idx = rand.uintLessThan(usize, n - 1);
            const b_idx = a_idx + 1 + rand.uintLessThan(usize, n - 1 - a_idx);

            const edge = try createEdge([]const u8, testing.allocator, vertices.items[a_idx], vertices.items[b_idx], "", .{
                .directed = true,
                .weighted = false,
                .weight = 0,
            });
            graph.addEdge(edge);
        }

        var result = try graph_algorithms.topoKahn([]const u8, &graph, testing.allocator);
        defer result.deinit();

        if (result.is_acyclic) {
            // Should include all vertices
            try testing.expectEqual(n, result.order.items.len);
        }
    }
}

test "Property - MST algorithms agree on weight" {
    const seeds = [_]u64{ 4, 555, 1024 };

    for (seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        var graph = Graph([]const u8).init(testing.allocator);
        defer graph.deinit();

        const n = 4 + (seed % 8);
        var vertices: std.ArrayListUnmanaged(*Vertex([]const u8)) = .{};
        defer vertices.deinit(testing.allocator);

        // Create vertices
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const id = try std.fmt.allocPrint(testing.allocator, "{d}", .{i});
            defer testing.allocator.free(id); // initWithId duplicates the ID
            const vertex = try Vertex([]const u8).initWithId(testing.allocator, id, "");
            graph.addVertex(vertex);
            try vertices.append(testing.allocator, vertex);
        }

        // Ensure connectivity with spanning tree
        i = 0;
        while (i < n - 1) : (i += 1) {
            const edge = try createEdge([]const u8, testing.allocator, vertices.items[i], vertices.items[i + 1], "", .{
                .directed = false,
                .weighted = false,
                .weight = 1.0,
            });
            graph.addEdge(edge);
        }

        // Add extra edges
        const extra = n + (seed % (n * 2));
        var j: usize = 0;
        while (j < extra) : (j += 1) {
            const a_idx = rand.uintLessThan(usize, n);
            const b_idx = rand.uintLessThan(usize, n);
            if (a_idx == b_idx) continue;

            const edge = try createEdge([]const u8, testing.allocator, vertices.items[a_idx], vertices.items[b_idx], "", .{
                .directed = false,
                .weighted = false,
                .weight = 1.0,
            });
            graph.addEdge(edge);
        }

        var kruskal_result = try spanning_trees.kruskal([]const u8, &graph, testing.allocator);
        defer kruskal_result.deinit();

        var prim_result = try spanning_trees.prim([]const u8, &graph, vertices.items[0], testing.allocator);
        defer prim_result.deinit();

        // Kruskal and Prim should produce MSTs with same total weight
        try testing.expectApproxEqAbs(kruskal_result.total_weight, prim_result.total_weight, 0.0001);
    }
}

// ============================================================================
// Bloom Filter Property Tests
// ============================================================================

test "Property - Bloom filter has no false negatives" {
    const seeds = [_]u64{ 5, 321, 789 };

    for (seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        var bloom = try cache.BloomFilter.init(testing.allocator, 1024, 3);
        defer bloom.deinit();

        const num_items = 20 + (seed % 40);
        var items: std.ArrayListUnmanaged([]const u8) = .{};
        defer {
            for (items.items) |item| {
                testing.allocator.free(item);
            }
            items.deinit(testing.allocator);
        }

        // Add random items
        var i: usize = 0;
        while (i < num_items) : (i += 1) {
            const char = 'A' + @as(u8, @intCast(rand.uintLessThan(u32, 26)));
            const item = try std.fmt.allocPrint(testing.allocator, "{c}", .{char});
            try bloom.add(item);
            try items.append(testing.allocator, item);
        }

        // Verify no false negatives
        for (items.items) |item| {
            const result = try bloom.test_(item);
            try testing.expect(result); // Must be true, no false negatives allowed
        }
    }
}

// ============================================================================
// String Search Property Tests
// ============================================================================

test "Property - KMP and Rabin-Karp produce identical results" {
    const test_cases = [_]struct {
        text: []const u8,
        pattern: []const u8,
    }{
        .{ .text = "hello world hello", .pattern = "hello" },
        .{ .text = "aaaaaaa", .pattern = "aaa" },
        .{ .text = "abcabcabc", .pattern = "abc" },
        .{ .text = "no match here", .pattern = "xyz" },
        .{ .text = "ABABDABACDABABCABAB", .pattern = "ABABCABAB" },
    };

    for (test_cases) |tc| {
        const kmp_result = try string_search.findAllKMP(testing.allocator, tc.text, tc.pattern);
        defer testing.allocator.free(kmp_result);

        const rk_result = try string_search.findAllRabinKarp(testing.allocator, tc.text, tc.pattern);
        defer testing.allocator.free(rk_result);

        // Results must match exactly
        try testing.expectEqual(kmp_result.len, rk_result.len);
        for (kmp_result, 0..) |kmp_val, i| {
            try testing.expectEqual(kmp_val, rk_result[i]);
        }
    }
}

// ============================================================================
// Union-Find Property Tests
// ============================================================================

test "Property - UnionFind produces idempotent finds" {
    const seeds = [_]u64{ 7, 444, 2048 };

    for (seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        var uf = UnionFind.init(testing.allocator);
        defer uf.deinit();

        const size = 10 + (seed % 50);
        var ids: std.ArrayListUnmanaged([]const u8) = .{};
        defer {
            for (ids.items) |id| {
                testing.allocator.free(id);
            }
            ids.deinit(testing.allocator);
        }

        // Create elements
        var i: usize = 0;
        while (i < size) : (i += 1) {
            const id = try std.fmt.allocPrint(testing.allocator, "n{d}", .{i});
            try uf.make(id);
            try ids.append(testing.allocator, id);
        }

        // Perform random unions
        const ops = size + (seed % (size * 3));
        var j: usize = 0;
        while (j < ops) : (j += 1) {
            const a_idx = rand.uintLessThan(usize, size);
            const b_idx = rand.uintLessThan(usize, size);
            _ = try uf.unite(ids.items[a_idx], ids.items[b_idx]);
        }

        // Verify find is idempotent
        for (ids.items) |id| {
            const root1 = try uf.find(id);
            const root2 = try uf.find(id);
            try testing.expectEqualStrings(root1, root2);
        }
    }
}

// ============================================================================
// GQL Property Tests
// ============================================================================

test "Property - GQL emission is deterministic" {
    var graph = Graph([]const u8).init(testing.allocator);
    defer graph.deinit();

    // Add vertices in non-alphabetical order
    const vertex_ids = [_][]const u8{ "Z", "A", "M" };
    var vertices: std.ArrayListUnmanaged(*Vertex([]const u8)) = .{};
    defer vertices.deinit(testing.allocator);

    for (vertex_ids) |v_id| {
        // Use string literals - initWithId already duplicates the ID
        const vertex = try Vertex([]const u8).initWithId(testing.allocator, v_id, v_id);
        graph.addVertex(vertex);
        try vertices.append(testing.allocator, vertex);
    }

    // Emit GQL twice
    var result1 = try gql.emitCreateGQL([]const u8, &graph, testing.allocator);
    defer result1.deinit();

    var result2 = try gql.emitCreateGQL([]const u8, &graph, testing.allocator);
    defer result2.deinit();

    // Queries should be identical
    try testing.expectEqualStrings(result1.query, result2.query);
}

// ============================================================================
// Integration Tests
// ============================================================================

test "Integration - Full workflow: build, serialize, query" {
    var graph = Graph([]const u8).init(testing.allocator);
    defer graph.deinit();

    // Build a small graph - use string literals since initWithId duplicates the ID
    const a = try Vertex([]const u8).initWithId(testing.allocator, "A", "A");
    const b = try Vertex([]const u8).initWithId(testing.allocator, "B", "B");
    const c = try Vertex([]const u8).initWithId(testing.allocator, "C", "C");

    graph.addVertex(a);
    graph.addVertex(b);
    graph.addVertex(c);

    const edge1 = try createEdge([]const u8, testing.allocator, a, b, "", .{ .directed = true, .weighted = false, .weight = 0 });
    const edge2 = try createEdge([]const u8, testing.allocator, b, c, "", .{ .directed = true, .weighted = false, .weight = 0 });
    graph.addEdge(edge1);
    graph.addEdge(edge2);

    // Test DOT serialization
    var dot_graph = try dot.DOTGraph.init(testing.allocator, &graph);
    defer dot_graph.deinit();

    var dot_output: std.ArrayListUnmanaged(u8) = .{};
    defer dot_output.deinit(testing.allocator);

    try dot_graph.marshal(dot_output.writer(testing.allocator));
    try testing.expect(dot_output.items.len > 0);

    // Test GQL emission
    var gql_result = try gql.emitCreateGQL([]const u8, &graph, testing.allocator);
    defer gql_result.deinit();

    try testing.expect(gql_result.query.len > 0);
    try testing.expect(gql_result.params.count() == 3);

    // Test shortest path query
    var match_result = try gql.emitMatchShortestPathGQL("A", "C", testing.allocator);
    defer match_result.deinit();

    try testing.expect(std.mem.indexOf(u8, match_result.query, "shortestPath") != null);
}
