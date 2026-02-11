// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("graph.zig").Graph;
const graph_core = @import("graph_core.zig");
const UnionFind = @import("unionfind.zig").UnionFind;

/// MSTResult holds the result of MST algorithms.
/// The edges field contains raw pointers that the user must cast to the appropriate Edge(T) type.
pub const MSTResult = struct {
    total_weight: f64,
    edges: std.ArrayListUnmanaged(*anyopaque),
    allocator: Allocator,

    pub fn deinit(self: *MSTResult) void {
        self.edges.deinit(self.allocator);
    }
};

/// EdgeWeight is used for sorting edges by weight.
const EdgeWeight = struct {
    weight: f64,
    a: []const u8,
    b: []const u8,
    edge: *anyopaque,
};

fn edgeKeyNormalized(comptime T: type, edge: *graph_core.Edge(T)) [2][]const u8 {
    var a: []const u8 = undefined;
    var b: []const u8 = undefined;

    switch (edge.*) {
        .basic => |basic| {
            a = basic.parent.id;
            b = basic.child.id;
        },
        .weighted => |weighted| {
            a = weighted.basic.parent.id;
            b = weighted.basic.child.id;
        },
        .directed => |directed| {
            a = directed.basic.parent.id;
            b = directed.basic.child.id;
        },
        .directed_weighted => |dw| {
            a = dw.weighted.basic.parent.id;
            b = dw.weighted.basic.child.id;
        },
    }

    if (std.mem.lessThan(u8, b, a)) {
        return [2][]const u8{ b, a };
    }
    return [2][]const u8{ a, b };
}

/// kruskal computes a Minimum Spanning Tree using Kruskal's algorithm.
/// For directed edges it ignores direction treating as undirected.
/// Unweighted edges are treated as weight=1.
pub fn kruskal(comptime T: type, graph: *Graph(T), allocator: Allocator) !MSTResult {
    var uf = UnionFind.init(allocator);
    defer uf.deinit();

    var edge_weights: std.ArrayListUnmanaged(EdgeWeight) = .{};
    defer edge_weights.deinit(allocator);

    // Collect all edges with their weights
    graph.edges_mutex.lock();
    for (graph.edges.items) |edge| {
        var a: []const u8 = undefined;
        var b: []const u8 = undefined;
        var weight: f64 = 1.0;

        switch (edge.*) {
            .basic => |basic| {
                a = basic.parent.id;
                b = basic.child.id;
            },
            .weighted => |weighted| {
                a = weighted.basic.parent.id;
                b = weighted.basic.child.id;
                weight = weighted.weight;
            },
            .directed => |directed| {
                a = directed.basic.parent.id;
                b = directed.basic.child.id;
            },
            .directed_weighted => |dw| {
                a = dw.weighted.basic.parent.id;
                b = dw.weighted.basic.child.id;
                weight = dw.weighted.weight;
            },
        }

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
            .edge = @ptrCast(edge),
        });

        try uf.make(ai);
        try uf.make(bi);
    }
    graph.edges_mutex.unlock();

    // Sort edges by weight, then by vertex IDs for deterministic ordering
    std.mem.sort(EdgeWeight, edge_weights.items, {}, struct {
        fn lessThan(_: void, a: EdgeWeight, b: EdgeWeight) bool {
            if (a.weight != b.weight) return a.weight < b.weight;
            const cmp_a = std.mem.order(u8, a.a, b.a);
            if (cmp_a == .eq) {
                return std.mem.lessThan(u8, a.b, b.b);
            }
            return cmp_a == .lt;
        }
    }.lessThan);

    var result = MSTResult{
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

    // Sort output edges for deterministic result
    std.mem.sort(*anyopaque, result.edges.items, {}, struct {
        fn lessThan(_: void, a: *anyopaque, b: *anyopaque) bool {
            const a_edge: *graph_core.Edge(T) = @ptrCast(@alignCast(a));
            const b_edge: *graph_core.Edge(T) = @ptrCast(@alignCast(b));
            const a_key = edgeKeyNormalized(T, a_edge);
            const b_key = edgeKeyNormalized(T, b_edge);
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
const PQItem = struct {
    weight: f64,
    from: []const u8,
    to: *anyopaque,
    to_id: []const u8,

    fn lessThan(_: void, a: PQItem, b: PQItem) std.math.Order {
        if (a.weight != b.weight) {
            return if (a.weight < b.weight) .lt else .gt;
        }
        const cmp_from = std.mem.order(u8, a.from, b.from);
        if (cmp_from != .eq) return cmp_from;
        return std.mem.order(u8, a.to_id, b.to_id);
    }
};

/// prim computes MST using Prim's algorithm starting from a given vertex.
/// Treats unweighted edges as weight=1.
pub fn prim(comptime T: type, _: *Graph(T), start: *graph_core.Vertex(T), allocator: Allocator) !MSTResult {
    var pq = std.PriorityQueue(PQItem, void, PQItem.lessThan).init(allocator, {});
    defer pq.deinit();

    var in_mst = std.StringHashMap(bool).init(allocator);
    defer in_mst.deinit();

    var result = MSTResult{
        .total_weight = 0,
        .edges = .{},
        .allocator = allocator,
    };

    const PushEdges = struct {
        fn call(
            v: *graph_core.Vertex(T),
            queue: *std.PriorityQueue(PQItem, void, PQItem.lessThan),
            mst_set: *std.StringHashMap(bool),
        ) !void {
            for (v.edges.items) |edge| {
                var a: *graph_core.Vertex(T) = undefined;
                var b: *graph_core.Vertex(T) = undefined;
                var weight: f64 = 1.0;

                switch (edge.*) {
                    .basic => |basic| {
                        a = basic.parent;
                        b = basic.child;
                    },
                    .weighted => |weighted| {
                        a = weighted.basic.parent;
                        b = weighted.basic.child;
                        weight = weighted.weight;
                    },
                    .directed => |directed| {
                        a = directed.basic.parent;
                        b = directed.basic.child;
                    },
                    .directed_weighted => |dw| {
                        a = dw.weighted.basic.parent;
                        b = dw.weighted.basic.child;
                        weight = dw.weighted.weight;
                    },
                }

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
                    .to = @ptrCast(b),
                    .to_id = b.id,
                });
            }
        }
    };

    try in_mst.put(start.id, true);
    try PushEdges.call(start, &pq, &in_mst);

    while (pq.count() > 0) {
        const item = pq.remove();
        const to_vertex: *graph_core.Vertex(T) = @ptrCast(@alignCast(item.to));

        if (in_mst.get(to_vertex.id) orelse false) continue;

        // Find the connecting edge
        var chosen: ?*graph_core.Edge(T) = null;
        for (to_vertex.edges.items) |edge| {
            var connects = false;
            switch (edge.*) {
                .basic => |basic| {
                    if ((std.mem.eql(u8, basic.parent.id, item.from) and basic.child == to_vertex) or
                        (std.mem.eql(u8, basic.child.id, item.from) and basic.parent == to_vertex))
                    {
                        connects = true;
                    }
                },
                .weighted => |weighted| {
                    if ((std.mem.eql(u8, weighted.basic.parent.id, item.from) and weighted.basic.child == to_vertex) or
                        (std.mem.eql(u8, weighted.basic.child.id, item.from) and weighted.basic.parent == to_vertex))
                    {
                        connects = true;
                    }
                },
                .directed => |directed| {
                    if ((std.mem.eql(u8, directed.basic.parent.id, item.from) and directed.basic.child == to_vertex) or
                        (std.mem.eql(u8, directed.basic.child.id, item.from) and directed.basic.parent == to_vertex))
                    {
                        connects = true;
                    }
                },
                .directed_weighted => |dw| {
                    if ((std.mem.eql(u8, dw.weighted.basic.parent.id, item.from) and dw.weighted.basic.child == to_vertex) or
                        (std.mem.eql(u8, dw.weighted.basic.child.id, item.from) and dw.weighted.basic.parent == to_vertex))
                    {
                        connects = true;
                    }
                },
            }

            if (connects) {
                chosen = edge;
                break;
            }
        }

        if (chosen) |edge| {
            try result.edges.append(allocator, @ptrCast(edge));
            result.total_weight += item.weight;
            try in_mst.put(to_vertex.id, true);
            try PushEdges.call(to_vertex, &pq, &in_mst);
        }
    }

    // Sort deterministically
    std.mem.sort(*anyopaque, result.edges.items, {}, struct {
        fn lessThan(_: void, a: *anyopaque, b: *anyopaque) bool {
            const a_edge: *graph_core.Edge(T) = @ptrCast(@alignCast(a));
            const b_edge: *graph_core.Edge(T) = @ptrCast(@alignCast(b));
            const a_key = edgeKeyNormalized(T, a_edge);
            const b_key = edgeKeyNormalized(T, b_edge);
            const cmp0 = std.mem.order(u8, a_key[0], b_key[0]);
            if (cmp0 == .eq) {
                return std.mem.lessThan(u8, a_key[1], b_key[1]);
            }
            return cmp0 == .lt;
        }
    }.lessThan);

    return result;
}
