// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("graph.zig").Graph;
const graph_core = @import("graph_core.zig");

/// PageRankResult holds PageRank scores and iteration count.
///
/// ## Allocator Ownership
///
/// The structure owns all memory for score map keys. Call `deinit()` to free.
pub const PageRankResult = struct {
    scores: std.StringHashMap(f64),
    iterations: usize,
    allocator: Allocator,

    pub fn deinit(self: *PageRankResult) void {
        var it = self.scores.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.scores.deinit();
    }
};

/// pageRank computes PageRank using power iteration with damping factor.
/// Handles sink nodes (outdegree 0) by distributing their rank uniformly.
pub fn pageRank(
    comptime T: type,
    graph: *Graph(T),
    damping: f64,
    tolerance: f64,
    max_iter: usize,
    allocator: Allocator,
) !PageRankResult {
    const damping_factor = if (damping <= 0 or damping >= 1) 0.85 else damping;
    const tol = if (tolerance <= 0) 1e-6 else tolerance;
    const max_iterations = if (max_iter == 0) 100 else max_iter;

    const verts = blk: {
        graph.vertices_mutex.lock();
        defer graph.vertices_mutex.unlock();
        break :blk try allocator.dupe(*graph_core.Vertex(T), graph.vertices.items);
    };
    defer allocator.free(verts);

    const n = @as(f64, @floatFromInt(verts.len));
    if (n == 0) {
        return PageRankResult{
            .scores = std.StringHashMap(f64).init(allocator),
            .iterations = 0,
            .allocator = allocator,
        };
    }

    // Initialize scores and compute out-degrees
    var pr = std.StringHashMap(f64).init(allocator);
    defer pr.deinit();

    var out_degree = std.StringHashMap(f64).init(allocator);
    defer out_degree.deinit();

    for (verts) |v| {
        const id = v.id;
        try pr.put(id, 1.0 / n);
        try out_degree.put(id, 0);
    }

    // Compute out-degrees
    {
        graph.edges_mutex.lock();
        defer graph.edges_mutex.unlock();

        for (graph.edges.items) |edge| {
            const edge_verts = edge.getVertices();
            const a_id = edge_verts[0].id;
            const b_id = edge_verts[1].id;

            if (edge.isDirected()) {
                const existing = out_degree.get(a_id) orelse 0;
                try out_degree.put(a_id, existing + 1);
            } else {
                // Treat undirected as bidirectional
                const existing_a = out_degree.get(a_id) orelse 0;
                const existing_b = out_degree.get(b_id) orelse 0;
                try out_degree.put(a_id, existing_a + 1);
                try out_degree.put(b_id, existing_b + 1);
            }
        }
    }

    // Allocate new_pr once and reuse across iterations (swap with pr each round)
    var new_pr = std.StringHashMap(f64).init(allocator);
    defer new_pr.deinit();

    var iter: usize = 1;
    while (iter <= max_iterations) : (iter += 1) {
        new_pr.clearRetainingCapacity();

        // Calculate sink sum (nodes with outdegree 0)
        var sink_sum: f64 = 0;
        for (verts) |v| {
            const id = v.id;
            const od = out_degree.get(id) orelse 0;
            if (od == 0) {
                sink_sum += pr.get(id) orelse 0;
            }
        }

        // Initialize new PageRank values
        for (verts) |v| {
            const id = v.id;
            const base_value = (1.0 - damping_factor) / n + damping_factor * (sink_sum / n);
            try new_pr.put(id, base_value);
        }

        // Distribute PageRank along edges
        {
            graph.edges_mutex.lock();
            defer graph.edges_mutex.unlock();

            for (graph.edges.items) |edge| {
                const edge_verts = edge.getVertices();
                const a_id = edge_verts[0].id;
                const b_id = edge_verts[1].id;

                if (edge.isDirected()) {
                    const od = out_degree.get(a_id) orelse 0;
                    if (od > 0) {
                        const contribution = damping_factor * (pr.get(a_id) orelse 0) / od;
                        const existing = new_pr.get(b_id) orelse 0;
                        try new_pr.put(b_id, existing + contribution);
                    }
                } else {
                    // Undirected: treat as bidirectional
                    const od_a = out_degree.get(a_id) orelse 0;
                    if (od_a > 0) {
                        const contribution = damping_factor * (pr.get(a_id) orelse 0) / od_a;
                        const existing = new_pr.get(b_id) orelse 0;
                        try new_pr.put(b_id, existing + contribution);
                    }

                    const od_b = out_degree.get(b_id) orelse 0;
                    if (od_b > 0) {
                        const contribution = damping_factor * (pr.get(b_id) orelse 0) / od_b;
                        const existing = new_pr.get(a_id) orelse 0;
                        try new_pr.put(a_id, existing + contribution);
                    }
                }
            }
        }

        // Check convergence
        var delta: f64 = 0;
        for (verts) |v| {
            const id = v.id;
            const old_val = pr.get(id) orelse 0;
            const new_val = new_pr.get(id) orelse 0;
            delta += @abs(new_val - old_val);
        }

        // Swap pr and new_pr to avoid per-entry copy
        std.mem.swap(std.StringHashMap(f64), &pr, &new_pr);

        if (delta < tol) {
            // Copy to result
            var result_scores = std.StringHashMap(f64).init(allocator);
            errdefer {
                var ki = result_scores.keyIterator();
                while (ki.next()) |k| allocator.free(k.*);
                result_scores.deinit();
            }
            var pr_it = pr.iterator();
            while (pr_it.next()) |entry| {
                const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                try result_scores.put(key_copy, entry.value_ptr.*);
            }

            return PageRankResult{
                .scores = result_scores,
                .iterations = iter,
                .allocator = allocator,
            };
        }
    }

    // Max iterations reached
    var result_scores = std.StringHashMap(f64).init(allocator);
    errdefer {
        var ki = result_scores.keyIterator();
        while (ki.next()) |k| allocator.free(k.*);
        result_scores.deinit();
    }
    var pr_it = pr.iterator();
    while (pr_it.next()) |entry| {
        const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
        try result_scores.put(key_copy, entry.value_ptr.*);
    }

    return PageRankResult{
        .scores = result_scores,
        .iterations = max_iterations,
        .allocator = allocator,
    };
}

/// CentralityResult holds betweenness and closeness centrality scores.
///
/// ## Allocator Ownership
///
/// The structure owns all memory for map keys. Call `deinit()` to free.
pub const CentralityResult = struct {
    betweenness: std.StringHashMap(f64),
    closeness: std.StringHashMap(f64),
    allocator: Allocator,

    pub fn deinit(self: *CentralityResult) void {
        var it = self.betweenness.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.betweenness.deinit();

        var it2 = self.closeness.keyIterator();
        while (it2.next()) |key| {
            self.allocator.free(key.*);
        }
        self.closeness.deinit();
    }
};

/// computeCentrality calculates betweenness and closeness centrality using Brandes algorithm.
pub fn computeCentrality(
    comptime T: type,
    graph: *Graph(T),
    allocator: Allocator,
) !CentralityResult {
    const verts = blk: {
        graph.vertices_mutex.lock();
        defer graph.vertices_mutex.unlock();
        break :blk try allocator.dupe(*graph_core.Vertex(T), graph.vertices.items);
    };
    defer allocator.free(verts);

    var bet = std.StringHashMap(f64).init(allocator);
    defer bet.deinit();
    var close_c = std.StringHashMap(f64).init(allocator);
    defer close_c.deinit();

    for (verts) |v| {
        try bet.put(v.id, 0);
        try close_c.put(v.id, 0);
    }

    // Build adjacency lists
    var adj = std.StringHashMap(std.ArrayListUnmanaged(*graph_core.Vertex(T))).init(allocator);
    defer {
        var it = adj.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        adj.deinit();
    }

    for (verts) |v| {
        const id_copy = try allocator.dupe(u8, v.id);
        try adj.put(id_copy, .{});
    }

    {
        graph.edges_mutex.lock();
        defer graph.edges_mutex.unlock();

        for (graph.edges.items) |edge| {
            const verts_pair = edge.getVertices();
            const a = verts_pair[0];
            const b = verts_pair[1];

            if (edge.isDirected()) {
                try adj.getPtr(a.id).?.append(allocator, b);
            } else {
                try adj.getPtr(a.id).?.append(allocator, b);
                try adj.getPtr(b.id).?.append(allocator, a);
            }
        }
    }

    // Sort adjacency lists for determinism
    var adj_it = adj.valueIterator();
    while (adj_it.next()) |list| {
        std.mem.sort(*graph_core.Vertex(T), list.items, {}, struct {
            fn lessThan(_: void, lhs: *graph_core.Vertex(T), rhs: *graph_core.Vertex(T)) bool {
                return std.mem.lessThan(u8, lhs.id, rhs.id);
            }
        }.lessThan);
    }

    // Pre-allocate data structures once (PERF-017: avoid alloc/dealloc per source)
    var stack: std.ArrayListUnmanaged(*graph_core.Vertex(T)) = .{};
    defer stack.deinit(allocator);

    var pred = std.StringHashMap(std.ArrayListUnmanaged(*graph_core.Vertex(T))).init(allocator);
    defer {
        var it = pred.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        pred.deinit();
    }

    var sigma = std.StringHashMap(f64).init(allocator);
    defer sigma.deinit();

    var dist_map = std.StringHashMap(i32).init(allocator);
    defer dist_map.deinit();

    var queue: std.ArrayListUnmanaged(*graph_core.Vertex(T)) = .{};
    defer queue.deinit(allocator);

    // Brandes algorithm for each source
    for (verts) |s| {
        // Clear per-source state, retaining capacity
        stack.clearRetainingCapacity();
        queue.clearRetainingCapacity();
        sigma.clearRetainingCapacity();
        dist_map.clearRetainingCapacity();
        // Clear pred lists but keep the hashmap entries
        var pred_it = pred.iterator();
        while (pred_it.next()) |entry| {
            entry.value_ptr.clearRetainingCapacity();
        }

        for (verts) |v| {
            const pred_entry = try pred.getOrPut(v.id);
            if (!pred_entry.found_existing) {
                pred_entry.value_ptr.* = .{};
            }
            try dist_map.put(v.id, -1);
            try sigma.put(v.id, 0);
        }

        try dist_map.put(s.id, 0);
        try sigma.put(s.id, 1);

        try queue.append(allocator, s);

        // BFS
        var queue_front: usize = 0;
        while (queue_front < queue.items.len) {
            const v = queue.items[queue_front];
            queue_front += 1;
            try stack.append(allocator, v);

            const neighbors = adj.get(v.id).?;
            for (neighbors.items) |w| {
                const w_id = w.id;
                const w_dist = dist_map.get(w_id).?;

                if (w_dist < 0) {
                    const v_dist = dist_map.get(v.id).?;
                    try dist_map.put(w_id, v_dist + 1);
                    try queue.append(allocator, w);
                }

                const v_dist = dist_map.get(v.id).?;
                const w_dist_check = dist_map.get(w_id).?;
                if (w_dist_check == v_dist + 1) {
                    const w_sigma = sigma.get(w_id).?;
                    const v_sigma = sigma.get(v.id).?;
                    try sigma.put(w_id, w_sigma + v_sigma);
                    try pred.getPtr(w_id).?.append(allocator, v);
                }
            }
        }

        // Closeness accumulation
        var sum_dist: i32 = 0;
        var reachable: i32 = 0;
        for (verts) |v| {
            const v_id = v.id;
            if (!std.mem.eql(u8, v_id, s.id)) {
                const vertex_d = dist_map.get(v_id).?;
                if (vertex_d > 0) {
                    sum_dist += vertex_d;
                    reachable += 1;
                }
            }
        }

        if (sum_dist > 0) {
            const closeness_val = @as(f64, @floatFromInt(reachable)) / @as(f64, @floatFromInt(sum_dist));
            try close_c.put(s.id, closeness_val);
        }

        // Dependency accumulation
        var delta_map = std.StringHashMap(f64).init(allocator);
        defer delta_map.deinit();

        for (verts) |v| {
            try delta_map.put(v.id, 0);
        }

        while (stack.items.len > 0) {
            const w_vert = stack.pop().?;
            const w_id = w_vert.id;
            const predecessors = pred.get(w_id).?;

            for (predecessors.items) |v| {
                const v_id = v.id;
                const w_sigma = sigma.get(w_id).?;
                if (w_sigma > 0) {
                    const v_sigma = sigma.get(v_id).?;
                    const w_delta = delta_map.get(w_id).?;
                    const contribution = (v_sigma / w_sigma) * (1.0 + w_delta);
                    const v_delta = delta_map.get(v_id).?;
                    try delta_map.put(v_id, v_delta + contribution);
                }
            }

            if (!std.mem.eql(u8, w_id, s.id)) {
                const w_bet = bet.get(w_id).?;
                const w_delta = delta_map.get(w_id).?;
                try bet.put(w_id, w_bet + w_delta);
            }
        }
    }

    // Normalize betweenness for undirected graphs
    if (!graph.isDirected()) {
        var bet_it = bet.iterator();
        while (bet_it.next()) |entry| {
            entry.value_ptr.* /= 2.0;
        }
    }

    // Copy to result
    var result_bet = std.StringHashMap(f64).init(allocator);
    errdefer {
        var ki = result_bet.keyIterator();
        while (ki.next()) |k| allocator.free(k.*);
        result_bet.deinit();
    }
    var bet_it = bet.iterator();
    while (bet_it.next()) |entry| {
        const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
        try result_bet.put(key_copy, entry.value_ptr.*);
    }

    var result_close = std.StringHashMap(f64).init(allocator);
    errdefer {
        var ki2 = result_close.keyIterator();
        while (ki2.next()) |k| allocator.free(k.*);
        result_close.deinit();
    }
    var close_it = close_c.iterator();
    while (close_it.next()) |entry| {
        const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
        try result_close.put(key_copy, entry.value_ptr.*);
    }

    return CentralityResult{
        .betweenness = result_bet,
        .closeness = result_close,
        .allocator = allocator,
    };
}
