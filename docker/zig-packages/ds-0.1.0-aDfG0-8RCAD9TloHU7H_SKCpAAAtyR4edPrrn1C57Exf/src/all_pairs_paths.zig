// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("graph.zig").Graph;
const graph_core = @import("graph_core.zig");
const shortest_paths = @import("shortest_paths.zig");
const Path = shortest_paths.Path;

/// BellmanFordResult holds all-pairs shortest paths from a source.
pub const BellmanFordResult = struct {
    distances: std.StringHashMap(f64),
    prev: std.StringHashMap([]const u8),
    has_negative_cycle: bool,
    allocator: Allocator,

    pub fn deinit(self: *BellmanFordResult) void {
        self.distances.deinit();
        var it = self.prev.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.prev.deinit();
    }

    /// Get path from source to destination.
    pub fn getPath(self: *BellmanFordResult, src_id: []const u8, dst_id: []const u8) !Path {
        const final_dist = self.distances.get(dst_id) orelse return Path.init(self.allocator);
        if (std.math.isInf(final_dist)) return Path.init(self.allocator);

        return shortest_paths.reconstructPath(self.allocator, &self.prev, src_id, dst_id, final_dist);
    }
};

/// Bellman-Ford shortest path algorithm.
/// Handles negative edge weights and detects negative cycles.
/// Time complexity: O(V * E)
pub fn bellmanFord(
    comptime T: type,
    graph: *Graph(T),
    src: *graph_core.Vertex(T),
    allocator: Allocator,
) !BellmanFordResult {
    var dist = std.StringHashMap(f64).init(allocator);
    errdefer dist.deinit();

    var prev = std.StringHashMap([]const u8).init(allocator);
    errdefer shortest_paths.deinitOwnedStringMap(allocator, &prev);

    // Initialize distances
    for (graph.getVertices()) |v| {
        try dist.put(v.id, std.math.inf(f64));
    }
    try dist.put(src.id, 0.0);

    const vertices = graph.getVertices();
    const n = vertices.len;

    // Early return for trivial graphs (also prevents 0..n-1 underflow)
    if (n <= 1) {
        return BellmanFordResult{
            .distances = dist,
            .prev = prev,
            .has_negative_cycle = false,
            .allocator = allocator,
        };
    }

    // Relax all edges |V| - 1 times
    for (0..n - 1) |_| {
        for (graph.getEdges()) |edge| {
            var u_id: []const u8 = "";
            var v_id: []const u8 = "";
            var weight: f64 = 1.0;

            if (edge.getWeight()) |w| weight = w;

            if (edge.isDirected()) {
                const parent = edge.getParent() orelse continue;
                const child = edge.getChild() orelse continue;
                u_id = parent.id;
                v_id = child.id;

                const du = dist.get(u_id) orelse continue;
                const dv = dist.get(v_id) orelse continue;

                if (!std.math.isInf(du) and du + weight < dv) {
                    try dist.put(v_id, du + weight);
                    if (prev.fetchRemove(v_id)) |removed| {
                        allocator.free(removed.key);
                        allocator.free(removed.value);
                    }
                    try prev.put(try allocator.dupe(u8, v_id), try allocator.dupe(u8, u_id));
                }
            } else {
                // Undirected: try both directions
                const verts = edge.getVertices();
                u_id = verts[0].id;
                v_id = verts[1].id;

                const du = dist.get(u_id) orelse continue;
                const dv = dist.get(v_id) orelse continue;

                if (!std.math.isInf(du) and du + weight < dv) {
                    try dist.put(v_id, du + weight);
                    if (prev.fetchRemove(v_id)) |removed| {
                        allocator.free(removed.key);
                        allocator.free(removed.value);
                    }
                    try prev.put(try allocator.dupe(u8, v_id), try allocator.dupe(u8, u_id));
                }
                if (!std.math.isInf(dv) and dv + weight < du) {
                    try dist.put(u_id, dv + weight);
                    if (prev.fetchRemove(u_id)) |removed| {
                        allocator.free(removed.key);
                        allocator.free(removed.value);
                    }
                    try prev.put(try allocator.dupe(u8, u_id), try allocator.dupe(u8, v_id));
                }
            }
        }
    }

    // Check for negative cycles
    var has_negative_cycle = false;
    for (graph.getEdges()) |edge| {
        var weight: f64 = 1.0;
        if (edge.getWeight()) |w| weight = w;

        if (edge.isDirected()) {
            const parent = edge.getParent() orelse continue;
            const child = edge.getChild() orelse continue;
            const du = dist.get(parent.id) orelse continue;
            const dv = dist.get(child.id) orelse continue;

            if (!std.math.isInf(du) and du + weight < dv) {
                has_negative_cycle = true;
                break;
            }
        } else {
            const verts = edge.getVertices();
            const du = dist.get(verts[0].id) orelse continue;
            const dv = dist.get(verts[1].id) orelse continue;

            if ((!std.math.isInf(du) and du + weight < dv) or
                (!std.math.isInf(dv) and dv + weight < du))
            {
                has_negative_cycle = true;
                break;
            }
        }
    }

    return BellmanFordResult{
        .distances = dist,
        .prev = prev,
        .has_negative_cycle = has_negative_cycle,
        .allocator = allocator,
    };
}

/// FloydWarshallResult holds all-pairs shortest paths.
///
/// Uses flat index-based arrays instead of string-keyed maps for O(1)
/// distance lookups with zero allocations per query.
pub const FloydWarshallResult = struct {
    /// Flat V*V distance matrix in row-major order: dist[i*V+j]
    dist: []f64,
    /// Flat V*V next-hop matrix for path reconstruction: next_hop[i*V+j]
    next_hop: []?usize,
    /// Maps vertex string ID -> dense integer index (0..V-1)
    id_to_index: std.StringHashMap(usize),
    /// Number of vertices
    vertex_count: usize,
    has_negative_cycle: bool,
    allocator: Allocator,

    pub fn deinit(self: *FloydWarshallResult) void {
        self.allocator.free(self.dist);
        self.allocator.free(self.next_hop);
        self.id_to_index.deinit();
    }

    /// Get distance between two vertices by their string IDs.
    /// Returns null if either vertex ID is unknown.
    /// This method performs NO allocations (pure index lookup).
    pub fn getDistance(self: *FloydWarshallResult, u: []const u8, v: []const u8) !?f64 {
        const ui = self.id_to_index.get(u) orelse return null;
        const vi = self.id_to_index.get(v) orelse return null;
        return self.dist[ui * self.vertex_count + vi];
    }
};

/// Floyd-Warshall all-pairs shortest paths algorithm.
/// Time complexity: O(V^3)
/// Space complexity: O(V^2)
///
/// Uses flat index-based arrays for the distance and next-hop matrices,
/// eliminating all string allocations from the V^3 inner loop.
pub fn floydWarshall(
    comptime T: type,
    graph: *Graph(T),
    allocator: Allocator,
) !FloydWarshallResult {
    const vertices = graph.getVertices();
    const n = vertices.len;

    // Build vertex ID -> dense integer index mapping
    var id_to_index = std.StringHashMap(usize).init(allocator);
    errdefer id_to_index.deinit();

    for (vertices, 0..) |v, idx| {
        try id_to_index.put(v.id, idx);
    }

    // Allocate flat distance matrix (V*V), initialized to infinity
    const matrix_size = std.math.mul(usize, n, n) catch return error.OutOfMemory;
    const dist = try allocator.alloc(f64, matrix_size);
    errdefer allocator.free(dist);
    @memset(dist, std.math.inf(f64));

    // Allocate flat next-hop matrix (V*V), initialized to null
    const next_hop = try allocator.alloc(?usize, matrix_size);
    errdefer allocator.free(next_hop);
    @memset(next_hop, null);

    // Initialize diagonal: dist[i][i] = 0
    for (0..n) |i| {
        dist[i * n + i] = 0.0;
    }

    // Initialize from edges
    for (graph.getEdges()) |edge| {
        var weight: f64 = 1.0;
        if (edge.getWeight()) |w| weight = w;

        if (edge.isDirected()) {
            const parent = edge.getParent() orelse continue;
            const child = edge.getChild() orelse continue;
            const ui = id_to_index.get(parent.id) orelse continue;
            const vi = id_to_index.get(child.id) orelse continue;
            const idx = ui * n + vi;

            if (weight < dist[idx]) {
                dist[idx] = weight;
                next_hop[idx] = vi;
            }
        } else {
            // Undirected: both directions
            const verts = edge.getVertices();
            const ui = id_to_index.get(verts[0].id) orelse continue;
            const vi = id_to_index.get(verts[1].id) orelse continue;

            const idx_uv = ui * n + vi;
            if (weight < dist[idx_uv]) {
                dist[idx_uv] = weight;
                next_hop[idx_uv] = vi;
            }

            const idx_vu = vi * n + ui;
            if (weight < dist[idx_vu]) {
                dist[idx_vu] = weight;
                next_hop[idx_vu] = ui;
            }
        }
    }

    // Floyd-Warshall main loop -- ZERO allocations in the inner loop
    for (0..n) |k| {
        for (0..n) |i| {
            const d_ik = dist[i * n + k];
            if (std.math.isInf(d_ik)) continue;

            for (0..n) |j| {
                const d_kj = dist[k * n + j];
                if (std.math.isInf(d_kj)) continue;

                const new_dist = d_ik + d_kj;
                const ij = i * n + j;
                if (new_dist < dist[ij]) {
                    dist[ij] = new_dist;
                    // next[i][j] = next[i][k]
                    next_hop[ij] = next_hop[i * n + k];
                }
            }
        }
    }

    // Check for negative cycles (negative values on diagonal)
    var has_negative_cycle = false;
    for (0..n) |i| {
        if (dist[i * n + i] < 0) {
            has_negative_cycle = true;
            break;
        }
    }

    return FloydWarshallResult{
        .dist = dist,
        .next_hop = next_hop,
        .id_to_index = id_to_index,
        .vertex_count = n,
        .has_negative_cycle = has_negative_cycle,
        .allocator = allocator,
    };
}
