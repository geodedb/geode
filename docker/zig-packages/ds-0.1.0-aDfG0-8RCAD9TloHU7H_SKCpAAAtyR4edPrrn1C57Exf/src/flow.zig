// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("graph.zig").Graph;
const graph_core = @import("graph_core.zig");

/// EdgeKey is a struct-based key for capacity maps, avoiding allocPrint in inner loops.
/// Uses the raw string slices (from/to vertex IDs) with content-based hashing.
const EdgeKey = struct {
    from: []const u8,
    to: []const u8,
};

/// Custom hash map context for EdgeKey that hashes on string content.
const EdgeKeyContext = struct {
    pub fn hash(_: @This(), key: EdgeKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(key.from);
        h.update(&[_]u8{0}); // separator to avoid collisions like ("ab","c") vs ("a","bc")
        h.update(key.to);
        return h.final();
    }

    pub fn eql(_: @This(), a: EdgeKey, b: EdgeKey) bool {
        return std.mem.eql(u8, a.from, b.from) and std.mem.eql(u8, a.to, b.to);
    }
};

/// HashMap type using EdgeKey for capacity lookups without string formatting.
const EdgeCapacityMap = std.HashMap(EdgeKey, f64, EdgeKeyContext, std.hash_map.default_max_load_percentage);

/// MaxFlowResult holds the result of max flow algorithms.
///
/// ## Allocator Ownership
///
/// The structure owns all memory for residual map keys. Call `deinit()` to free.
pub const MaxFlowResult = struct {
    flow: f64,
    /// Residual capacities keyed by "u->v"
    residual: std.StringHashMap(f64),

    pub fn deinit(self: *MaxFlowResult) void {
        var it = self.residual.keyIterator();
        while (it.next()) |key| {
            self.residual.allocator.free(key.*);
        }
        self.residual.deinit();
    }
};

/// edmondsKarp computes maximum flow using Edmonds-Karp algorithm (BFS-based Ford-Fulkerson).
/// For directed weighted edges, capacity == weight. Unweighted edges have capacity 1.
/// Undirected edges are treated as bidirectional with same capacity.
///
/// **Concurrency note:** Acquires the graph mutex for the duration of the
/// computation (O(V*E^2)), blocking all other graph operations until complete.
pub fn edmondsKarp(
    comptime T: type,
    graph: *Graph(T),
    src: *graph_core.Vertex(T),
    dst: *graph_core.Vertex(T),
    allocator: Allocator,
) !MaxFlowResult {
    if (src == dst) {
        return MaxFlowResult{
            .flow = 0,
            .residual = std.StringHashMap(f64).init(allocator),
        };
    }

    // Build capacity map (struct-keyed, no allocPrint) and adjacency list
    var capacity = EdgeCapacityMap.init(allocator);
    defer capacity.deinit();

    var adjacency = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator);
    defer {
        var it = adjacency.valueIterator();
        while (it.next()) |list| {
            for (list.items) |id| {
                allocator.free(id);
            }
            list.deinit(allocator);
        }
        var key_it = adjacency.keyIterator();
        while (key_it.next()) |key| {
            allocator.free(key.*);
        }
        adjacency.deinit();
    }

    const AddEdge = struct {
        fn call(
            u_id: []const u8,
            v_id: []const u8,
            c: f64,
            cap: *EdgeCapacityMap,
            adj: *std.StringHashMap(std.ArrayListUnmanaged([]const u8)),
            alloc: Allocator,
        ) !void {
            if (c < 0) return;

            // Update capacity using struct key (no allocPrint)
            const edge_key = EdgeKey{ .from = u_id, .to = v_id };
            const existing = cap.get(edge_key) orelse 0;
            try cap.put(edge_key, existing + c);

            // Update adjacency list
            if (!adj.contains(u_id)) {
                const u_copy = try alloc.dupe(u8, u_id);
                try adj.put(u_copy, .{});
            }
            var u_list = adj.getPtr(u_id).?;
            const v_copy = try alloc.dupe(u8, v_id);
            try u_list.append(alloc, v_copy);

            // Ensure v exists in adjacency
            if (!adj.contains(v_id)) {
                const v_copy_key = try alloc.dupe(u8, v_id);
                try adj.put(v_copy_key, .{});
            }
        }
    };

    {
        graph.edges_mutex.lock();
        defer graph.edges_mutex.unlock();

        for (graph.edges.items) |edge| {
            const verts = edge.getVertices();
            const u_id = verts[0].id;
            const v_id = verts[1].id;
            const c: f64 = edge.getWeight() orelse 1.0;

            // Add edges based on directedness
            if (edge.isDirected()) {
                try AddEdge.call(u_id, v_id, c, &capacity, &adjacency, allocator);
                try AddEdge.call(v_id, u_id, 0, &capacity, &adjacency, allocator);
            } else {
                // Undirected: bidirectional
                try AddEdge.call(u_id, v_id, c, &capacity, &adjacency, allocator);
                try AddEdge.call(v_id, u_id, c, &capacity, &adjacency, allocator);
            }
        }
    }

    const src_id = src.id;
    const dst_id = dst.id;
    var total_flow: f64 = 0;

    // Pre-allocate BFS structures once (PERF-018: avoid alloc/dealloc per BFS pass)
    var prev = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = prev.valueIterator();
        while (it.next()) |val| {
            allocator.free(val.*);
        }
        prev.deinit();
    }

    var bfs_queue: std.ArrayListUnmanaged([]const u8) = .{};
    defer bfs_queue.deinit(allocator);

    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();

    // Edmonds-Karp: repeatedly find augmenting paths using BFS
    while (true) {
        // Clear per-pass state, retaining capacity
        {
            var it = prev.valueIterator();
            while (it.next()) |val| {
                allocator.free(val.*);
            }
        }
        prev.clearRetainingCapacity();
        bfs_queue.clearRetainingCapacity();
        visited.clearRetainingCapacity();

        try bfs_queue.append(allocator, src_id);
        try visited.put(src_id, {});

        var queue_front: usize = 0;
        while (queue_front < bfs_queue.items.len) {
            const u_id = bfs_queue.items[queue_front];
            queue_front += 1;

            if (std.mem.eql(u8, u_id, dst_id)) break;

            const neighbors = adjacency.get(u_id) orelse continue;
            for (neighbors.items) |v_id| {
                if (visited.contains(v_id)) continue;

                // Struct-key lookup: no allocPrint needed
                const cap_val = capacity.get(.{ .from = u_id, .to = v_id }) orelse 0;

                if (cap_val <= 0) continue;

                try visited.put(v_id, {});
                const u_copy = try allocator.dupe(u8, u_id);
                try prev.put(v_id, u_copy);
                try bfs_queue.append(allocator, v_id);
            }
        }

        if (!prev.contains(dst_id)) break; // No augmenting path

        // Find bottleneck
        var bottleneck: f64 = std.math.floatMax(f64);
        var v_id = dst_id;
        while (!std.mem.eql(u8, v_id, src_id)) {
            const u_id = prev.get(v_id).?;
            // Struct-key lookup: no allocPrint needed
            const cap_val = capacity.get(.{ .from = u_id, .to = v_id }) orelse 0;
            bottleneck = @min(bottleneck, cap_val);
            v_id = u_id;
        }

        // Augment flow along path
        v_id = dst_id;
        while (!std.mem.eql(u8, v_id, src_id)) {
            const u_id = prev.get(v_id).?;

            // Struct-key update: no allocPrint needed
            const forward_key = EdgeKey{ .from = u_id, .to = v_id };
            const forward_cap = capacity.get(forward_key).?;
            try capacity.put(forward_key, forward_cap - bottleneck);

            const backward_key = EdgeKey{ .from = v_id, .to = u_id };
            const backward_cap = capacity.get(backward_key) orelse 0;
            try capacity.put(backward_key, backward_cap + bottleneck);

            v_id = u_id;
        }

        total_flow += bottleneck;
    }

    // Build residual capacity map (convert struct keys to "u->v" strings for public API)
    var residual = std.StringHashMap(f64).init(allocator);
    var cap_it = capacity.iterator();
    while (cap_it.next()) |entry| {
        const key = entry.key_ptr.*;
        const str_key = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ key.from, key.to });
        try residual.put(str_key, entry.value_ptr.*);
    }

    return MaxFlowResult{
        .flow = total_flow,
        .residual = residual,
    };
}

/// DinicEdge represents an edge in Dinic's residual graph.
const DinicEdge = struct {
    to: []const u8,
    rev: usize,
    cap: f64,
};

/// dinic computes maximum flow using Dinic's algorithm.
/// Uses level graph (BFS) and blocking flow (DFS).
///
/// **Concurrency note:** Acquires the graph mutex for the duration of the
/// computation, blocking all other graph operations until complete.
pub fn dinic(
    comptime T: type,
    graph: *Graph(T),
    src: *graph_core.Vertex(T),
    dst: *graph_core.Vertex(T),
    allocator: Allocator,
) !MaxFlowResult {
    if (src == dst) {
        return MaxFlowResult{
            .flow = 0,
            .residual = std.StringHashMap(f64).init(allocator),
        };
    }

    // Build adjacency list with reverse edges
    var adj = std.StringHashMap(std.ArrayListUnmanaged(DinicEdge)).init(allocator);
    defer {
        var it = adj.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        adj.deinit();
    }

    const AddEdge = struct {
        fn call(
            u_id: []const u8,
            v_id: []const u8,
            c: f64,
            adjacency: *std.StringHashMap(std.ArrayListUnmanaged(DinicEdge)),
            alloc: Allocator,
        ) !void {
            if (!adjacency.contains(u_id)) {
                const u_copy = try alloc.dupe(u8, u_id);
                try adjacency.put(u_copy, .{});
            }
            if (!adjacency.contains(v_id)) {
                const v_copy = try alloc.dupe(u8, v_id);
                try adjacency.put(v_copy, .{});
            }

            const v_list_len = adjacency.get(v_id).?.items.len;
            const u_list = adjacency.getPtr(u_id).?;
            try u_list.append(alloc, .{ .to = v_id, .rev = v_list_len, .cap = c });

            const u_list_len = u_list.items.len - 1;
            const v_list = adjacency.getPtr(v_id).?;
            try v_list.append(alloc, .{ .to = u_id, .rev = u_list_len, .cap = 0 });
        }
    };

    {
        graph.edges_mutex.lock();
        defer graph.edges_mutex.unlock();

        for (graph.edges.items) |edge| {
            const verts = edge.getVertices();
            const u_id = verts[0].id;
            const v_id = verts[1].id;
            const c: f64 = edge.getWeight() orelse 1.0;

            if (edge.isDirected()) {
                try AddEdge.call(u_id, v_id, c, &adj, allocator);
            } else {
                try AddEdge.call(u_id, v_id, c, &adj, allocator);
                try AddEdge.call(v_id, u_id, c, &adj, allocator);
            }
        }
    }

    const src_id = src.id;
    const dst_id = dst.id;

    var level = std.StringHashMap(i32).init(allocator);
    defer level.deinit();

    const BFS = struct {
        fn call(
            s: []const u8,
            t: []const u8,
            adjacency: *std.StringHashMap(std.ArrayListUnmanaged(DinicEdge)),
            levels: *std.StringHashMap(i32),
            alloc: Allocator,
        ) !bool {
            levels.clearRetainingCapacity();

            var queue: std.ArrayListUnmanaged([]const u8) = .{};
            defer queue.deinit(alloc);

            try levels.put(s, 0);
            try queue.append(alloc, s);

            var queue_front: usize = 0;
            while (queue_front < queue.items.len) {
                const u = queue.items[queue_front];
                queue_front += 1;
                const u_level = levels.get(u).?;

                const neighbors = adjacency.get(u) orelse continue;
                for (neighbors.items) |edge| {
                    if (edge.cap > 0 and !levels.contains(edge.to)) {
                        try levels.put(edge.to, u_level + 1);
                        try queue.append(alloc, edge.to);
                    }
                }
            }

            return levels.contains(t);
        }
    };

    var iter_map = std.StringHashMap(usize).init(allocator);
    defer iter_map.deinit();

    const DFS = struct {
        fn call(
            u: []const u8,
            t: []const u8,
            f: f64,
            adjacency: *std.StringHashMap(std.ArrayListUnmanaged(DinicEdge)),
            levels: *std.StringHashMap(i32),
            iters: *std.StringHashMap(usize),
        ) f64 {
            if (std.mem.eql(u8, u, t)) return f;

            const u_level = levels.get(u).?;
            const u_edges = adjacency.getPtr(u).?;
            const start_iter = iters.get(u) orelse 0;

            var i = start_iter;
            while (i < u_edges.items.len) : (i += 1) {
                // Keys are pre-populated; mutate in-place via getPtr
                if (iters.getPtr(u)) |ptr| {
                    ptr.* = i + 1;
                }

                const edge = &u_edges.items[i];
                if (edge.cap <= 0) continue;

                const to_level = levels.get(edge.to) orelse continue;
                if (to_level != u_level + 1) continue;

                const pushed = call(edge.to, t, @min(f, edge.cap), adjacency, levels, iters);
                if (pushed > 0) {
                    // Update residual graph
                    edge.cap -= pushed;
                    const rev_idx = edge.rev;
                    adjacency.getPtr(edge.to).?.items[rev_idx].cap += pushed;
                    return pushed;
                }
            }

            return 0;
        }
    };

    var total_flow: f64 = 0;

    // Pre-populate iter_map with all vertices to avoid allocation in DFS
    var adj_keys = adj.keyIterator();
    while (adj_keys.next()) |key| {
        try iter_map.put(key.*, 0);
    }

    while (try BFS.call(src_id, dst_id, &adj, &level, allocator)) {
        // Reset all iteration counters to 0 (no allocation needed since keys exist)
        var iter_it = iter_map.iterator();
        while (iter_it.next()) |entry| {
            entry.value_ptr.* = 0;
        }

        while (true) {
            const pushed = DFS.call(src_id, dst_id, std.math.floatMax(f64), &adj, &level, &iter_map);
            if (pushed == 0) break;
            total_flow += pushed;
        }
    }

    // Build residual capacity map
    var residual = std.StringHashMap(f64).init(allocator);
    var adj_it = adj.iterator();
    while (adj_it.next()) |entry| {
        for (entry.value_ptr.items) |edge| {
            const key = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ entry.key_ptr.*, edge.to });
            try residual.put(key, edge.cap);
        }
    }

    return MaxFlowResult{
        .flow = total_flow,
        .residual = residual,
    };
}
