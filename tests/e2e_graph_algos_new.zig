// E2E coverage for the real community-detection entry points exported via the
// geode root module (`geode.graph.community_louvain` / `community_label_propagation`).
//
// GAP-0863a: this file previously imported a `graph_algos_stub` API that was
// never exported by src/lib.zig (and the stub surface is slated for removal by
// GAP-0883), so the test exercised nothing real and broke the `test-e2e`
// compile.  Rewritten against the shipping algorithms over a small in-memory
// adjacency-list graph: two triangles joined by a single bridge edge.
//
// CANARY: REQ=REQ-GRAPH-LOUVAIN-001; FEATURE="LouvainCommunityDetection"; ASPECT=E2ECommunityDetection; STATUS=TESTED; TEST=tests/e2e_graph_algos_new.zig; OWNER=graph; UPDATED=2026-06-10

const std = @import("std");
const louvain = @import("geode").graph.community_louvain;
const label_prop = @import("geode").graph.community_label_propagation;

// Undirected graph as adjacency lists (each edge listed in both directions):
//   triangle A: 0-1, 1-2, 2-0
//   triangle B: 3-4, 4-5, 5-3
//   bridge:     2-3
fn twoTriangleGraph() [6][]const u64 {
    return .{
        &[_]u64{ 1, 2 },
        &[_]u64{ 0, 2 },
        &[_]u64{ 0, 1, 3 },
        &[_]u64{ 2, 4, 5 },
        &[_]u64{ 3, 5 },
        &[_]u64{ 3, 4 },
    };
}

fn mutableGraph(allocator: std.mem.Allocator) ![][]u64 {
    const fixed = twoTriangleGraph();
    const graph = try allocator.alloc([]u64, fixed.len);
    var filled: usize = 0;
    errdefer {
        for (graph[0..filled]) |row| allocator.free(row);
        allocator.free(graph);
    }
    for (fixed, 0..) |row, i| {
        graph[i] = try allocator.dupe(u64, row);
        filled += 1;
    }
    return graph;
}

fn freeGraph(allocator: std.mem.Allocator, graph: [][]u64) void {
    for (graph) |row| allocator.free(row);
    allocator.free(graph);
}

test "louvain detects the two triangle communities" {
    const allocator = std.testing.allocator;
    const graph = try mutableGraph(allocator);
    defer freeGraph(allocator, graph);

    const labels = try louvain.detect(allocator, graph, 1.0, 1e-6);
    defer allocator.free(labels);

    try std.testing.expectEqual(@as(usize, 6), labels.len);
    // Each triangle must be assigned a single community...
    try std.testing.expectEqual(labels[0], labels[1]);
    try std.testing.expectEqual(labels[1], labels[2]);
    try std.testing.expectEqual(labels[3], labels[4]);
    try std.testing.expectEqual(labels[4], labels[5]);
    // ...and the bridge edge must not merge the triangles.
    try std.testing.expect(labels[0] != labels[3]);
}

test "louvain result is deterministic across runs" {
    const allocator = std.testing.allocator;
    const graph = try mutableGraph(allocator);
    defer freeGraph(allocator, graph);

    const first = try louvain.detect(allocator, graph, 1.0, 1e-6);
    defer allocator.free(first);
    const second = try louvain.detect(allocator, graph, 1.0, 1e-6);
    defer allocator.free(second);

    try std.testing.expectEqualSlices(u64, first, second);
}

test "louvain communities improve modularity over singletons" {
    const allocator = std.testing.allocator;
    const graph = try mutableGraph(allocator);
    defer freeGraph(allocator, graph);

    const labels = try louvain.detect(allocator, graph, 1.0, 1e-6);
    defer allocator.free(labels);

    var singletons: [6]u64 = .{ 0, 1, 2, 3, 4, 5 };
    const detected_q = louvain.modularity(graph, labels, 1.0);
    const singleton_q = louvain.modularity(graph, &singletons, 1.0);
    try std.testing.expect(detected_q > singleton_q);
}

test "label propagation finds the two triangle communities deterministically" {
    const allocator = std.testing.allocator;
    const graph = try mutableGraph(allocator);
    defer freeGraph(allocator, graph);

    const labels = try label_prop.detect(allocator, graph, 100);
    defer allocator.free(labels);

    try std.testing.expectEqual(@as(usize, 6), labels.len);
    try std.testing.expectEqual(labels[0], labels[1]);
    try std.testing.expectEqual(labels[1], labels[2]);
    try std.testing.expectEqual(labels[3], labels[4]);
    try std.testing.expectEqual(labels[4], labels[5]);
    try std.testing.expectEqual(@as(usize, 2), label_prop.countCommunities(labels));

    // Seeded PRNG (fixed seed inside detect) makes repeat runs identical.
    const repeat = try label_prop.detect(allocator, graph, 100);
    defer allocator.free(repeat);
    try std.testing.expectEqualSlices(u64, labels, repeat);
}

test "community detection handles the empty graph" {
    const allocator = std.testing.allocator;
    var empty: [0][]u64 = .{};

    const labels = try louvain.detect(allocator, &empty, 1.0, 1e-6);
    defer if (labels.len > 0) allocator.free(labels);
    try std.testing.expectEqual(@as(usize, 0), labels.len);
}
