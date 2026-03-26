// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("graph.zig").Graph;
const graph_core = @import("graph_core.zig");
const UnionFind = @import("unionfind.zig").UnionFind;

/// MSTResult holds the result of MST algorithms.
///
/// Generic over `T` so the `edges` field stores fully typed
/// `*graph_core.Edge(T)` pointers, eliminating the need for
/// `*anyopaque` and unsafe casts.
pub fn MSTResult(comptime T: type) type {
    return struct {
        const Self = @This();

        total_weight: f64,
        edges: std.ArrayListUnmanaged(*graph_core.Edge(T)),
        allocator: Allocator,

        pub fn deinit(self: *Self) void {
            self.edges.deinit(self.allocator);
        }
    };
}

/// EdgeWeight is used for sorting edges by weight.
fn EdgeWeight(comptime T: type) type {
    return struct {
        weight: f64,
        a: []const u8,
        b: []const u8,
        edge: *graph_core.Edge(T),
    };
}

fn edgeKeyNormalized(comptime T: type, edge: *graph_core.Edge(T)) [2][]const u8 {
    const verts = edge.getVertices();
    const a = verts[0].id;
    const b = verts[1].id;

    if (std.mem.lessThan(u8, b, a)) {
        return [2][]const u8{ b, a };
    }
    return [2][]const u8{ a, b };
}

/// kruskal computes a Minimum Spanning Tree using Kruskal's algorithm.
/// For directed edges it ignores direction treating as undirected.
/// Unweighted edges are treated as weight=1.
pub fn kruskal(comptime T: type, graph: *Graph(T), allocator: Allocator) !MSTResult(T) {
    var uf = UnionFind.init(allocator);
    defer uf.deinit();

    var edge_weights: std.ArrayListUnmanaged(EdgeWeight(T)) = .{};
    defer edge_weights.deinit(allocator);

    // Collect all edges with their weights
    {
        graph.edges_mutex.lock();
        defer graph.edges_mutex.unlock();

        for (graph.edges.items) |edge| {
            const verts = edge.getVertices();
            const a = verts[0].id;
            const b = verts[1].id;
            const weight: f64 = edge.getWeight() orelse 1.0;

            // Normalize order
            var ai = a;
            var bi = b;
            if (std.mem.lessThan(u8, bi, ai)) {
                const tmp = ai;
                ai = bi;
                bi = tmp;
            }

            try edge_weights.append(allocator, .{
                .weight = weight,
                .a = ai,
                .b = bi,
                .edge = edge,
            });

            try uf.make(ai);
            try uf.make(bi);
        }
    }

    // Sort edges by weight, then by vertex IDs for deterministic ordering
    std.mem.sort(EdgeWeight(T), edge_weights.items, {}, struct {
        fn lessThan(_: void, a: EdgeWeight(T), b: EdgeWeight(T)) bool {
            if (a.weight != b.weight) return a.weight < b.weight;
            const cmp_a = std.mem.order(u8, a.a, b.a);
            if (cmp_a == .eq) {
                return std.mem.lessThan(u8, a.b, b.b);
            }
            return cmp_a == .lt;
        }
    }.lessThan);

    var result = MSTResult(T){
        .total_weight = 0,
        .edges = .{},
        .allocator = allocator,
    };

    // Kruskal's algorithm: add edges that don't create cycles
    for (edge_weights.items) |ew| {
        if (try uf.unite(ew.a, ew.b)) {
            result.total_weight += ew.weight;
            try result.edges.append(allocator, ew.edge);
        }
    }

    // Sort output edges for deterministic result.
    std.mem.sort(*graph_core.Edge(T), result.edges.items, {}, struct {
        fn lessThan(_: void, a: *graph_core.Edge(T), b: *graph_core.Edge(T)) bool {
            const a_key = edgeKeyNormalized(T, a);
            const b_key = edgeKeyNormalized(T, b);
            const cmp0 = std.mem.order(u8, a_key[0], b_key[0]);
            if (cmp0 == .eq) {
                return std.mem.lessThan(u8, a_key[1], b_key[1]);
            }
            return cmp0 == .lt;
        }
    }.lessThan);

    return result;
}

/// PQItem for Prim's algorithm priority queue.
fn PQItem(comptime T: type) type {
    return struct {
        const Self = @This();

        weight: f64,
        from: []const u8,
        to: *graph_core.Vertex(T),
        to_id: []const u8,

        fn lessThan(_: void, a: Self, b: Self) std.math.Order {
            if (a.weight != b.weight) {
                return if (a.weight < b.weight) .lt else .gt;
            }
            const cmp_from = std.mem.order(u8, a.from, b.from);
            if (cmp_from != .eq) return cmp_from;
            return std.mem.order(u8, a.to_id, b.to_id);
        }
    };
}

/// prim computes MST using Prim's algorithm starting from a given vertex.
/// Treats unweighted edges as weight=1.
pub fn prim(comptime T: type, start: *graph_core.Vertex(T), allocator: Allocator) !MSTResult(T) {
    const PQ = PQItem(T);
    var pq = std.PriorityQueue(PQ, void, PQ.lessThan).init(allocator, {});
    defer pq.deinit();

    var in_mst = std.StringHashMap(bool).init(allocator);
    defer in_mst.deinit();

    var result = MSTResult(T){
        .total_weight = 0,
        .edges = .{},
        .allocator = allocator,
    };

    const PushEdges = struct {
        fn call(
            v: *graph_core.Vertex(T),
            queue: *std.PriorityQueue(PQ, void, PQ.lessThan),
            mst_set: *std.StringHashMap(bool),
        ) !void {
            for (v.edges.items) |edge| {
                const verts = edge.getVertices();
                var a = verts[0];
                var b = verts[1];
                const weight: f64 = edge.getWeight() orelse 1.0;

                // Ensure correct direction (from v to the other vertex)
                if (a != v) {
                    const tmp = a;
                    a = b;
                    b = tmp;
                }

                if (mst_set.get(b.id) orelse false) continue;

                try queue.add(.{
                    .weight = weight,
                    .from = a.id,
                    .to = b,
                    .to_id = b.id,
                });
            }
        }
    };

    try in_mst.put(start.id, true);
    try PushEdges.call(start, &pq, &in_mst);

    while (pq.count() > 0) {
        const item = pq.remove();
        const to_vertex = item.to;

        if (in_mst.get(to_vertex.id) orelse false) continue;

        // Find the connecting edge
        var chosen: ?*graph_core.Edge(T) = null;
        for (to_vertex.edges.items) |edge| {
            const ev = edge.getVertices();
            const connects = (std.mem.eql(u8, ev[0].id, item.from) and ev[1] == to_vertex) or
                (std.mem.eql(u8, ev[1].id, item.from) and ev[0] == to_vertex);

            if (connects) {
                chosen = edge;
                break;
            }
        }

        if (chosen) |edge| {
            try result.edges.append(allocator, edge);
            result.total_weight += item.weight;
            try in_mst.put(to_vertex.id, true);
            try PushEdges.call(to_vertex, &pq, &in_mst);
        }
    }

    // Sort deterministically.
    std.mem.sort(*graph_core.Edge(T), result.edges.items, {}, struct {
        fn lessThan(_: void, a: *graph_core.Edge(T), b: *graph_core.Edge(T)) bool {
            const a_key = edgeKeyNormalized(T, a);
            const b_key = edgeKeyNormalized(T, b);
            const cmp0 = std.mem.order(u8, a_key[0], b_key[0]);
            if (cmp0 == .eq) {
                return std.mem.lessThan(u8, a_key[1], b_key[1]);
            }
            return cmp0 == .lt;
        }
    }.lessThan);

    return result;
}
