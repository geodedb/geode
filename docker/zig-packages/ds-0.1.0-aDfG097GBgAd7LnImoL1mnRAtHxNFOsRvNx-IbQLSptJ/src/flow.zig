// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("graph.zig").Graph;
const graph_core = @import("graph_core.zig");

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

    // Build capacity map and adjacency list
    var capacity = std.StringHashMap(f64).init(allocator);
    defer {
        var cap_key_it = capacity.keyIterator();
        while (cap_key_it.next()) |key| {
            allocator.free(key.*);
        }
        capacity.deinit();
    }

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
            cap: *std.StringHashMap(f64),
            adj: *std.StringHashMap(std.ArrayListUnmanaged([]const u8)),
            alloc: Allocator,
        ) !void {
            if (c < 0) return;

            // Update capacity
            const key = try std.fmt.allocPrint(alloc, "{s}->{s}", .{ u_id, v_id });
            const existing = cap.get(key) orelse 0;
            try cap.put(key, existing + c);

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

    graph.edges_mutex.lock();
    for (graph.edges.items) |edge| {
        var u_id: []const u8 = undefined;
        var v_id: []const u8 = undefined;
        var c: f64 = 1.0;

        switch (edge.*) {
            .basic => |basic| {
                u_id = basic.parent.id;
                v_id = basic.child.id;
            },
            .weighted => |weighted| {
                u_id = weighted.basic.parent.id;
                v_id = weighted.basic.child.id;
                c = weighted.weight;
            },
            .directed => |directed| {
                u_id = directed.basic.parent.id;
                v_id = directed.basic.child.id;
            },
            .directed_weighted => |dw| {
                u_id = dw.weighted.basic.parent.id;
                v_id = dw.weighted.basic.child.id;
                c = dw.weighted.weight;
            },
        }

        // Add edges based on directedness
        if (edge.* == .directed or edge.* == .directed_weighted) {
            try AddEdge.call(u_id, v_id, c, &capacity, &adjacency, allocator);
            try AddEdge.call(v_id, u_id, 0, &capacity, &adjacency, allocator);
        } else {
            // Undirected: bidirectional
            try AddEdge.call(u_id, v_id, c, &capacity, &adjacency, allocator);
            try AddEdge.call(v_id, u_id, c, &capacity, &adjacency, allocator);
        }
    }
    graph.edges_mutex.unlock();

    const src_id = src.id;
    const dst_id = dst.id;
    var total_flow: f64 = 0;

    // Edmonds-Karp: repeatedly find augmenting paths using BFS
    while (true) {
        // BFS to find augmenting path
        var prev = std.StringHashMap([]const u8).init(allocator);
        defer {
            var it = prev.valueIterator();
            while (it.next()) |val| {
                allocator.free(val.*);
            }
            prev.deinit();
        }

        var queue: std.ArrayListUnmanaged([]const u8) = .{};
        defer queue.deinit(allocator);

        var visited = std.StringHashMap(void).init(allocator);
        defer visited.deinit();

        try queue.append(allocator, src_id);
        try visited.put(src_id, {});

        while (queue.items.len > 0) {
            const u_id = queue.orderedRemove(0);

            if (std.mem.eql(u8, u_id, dst_id)) break;

            const neighbors = adjacency.get(u_id) orelse continue;
            for (neighbors.items) |v_id| {
                if (visited.contains(v_id)) continue;

                const cap_key = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ u_id, v_id });
                defer allocator.free(cap_key);
                const cap_val = capacity.get(cap_key) orelse 0;

                if (cap_val <= 0) continue;

                try visited.put(v_id, {});
                const u_copy = try allocator.dupe(u8, u_id);
                try prev.put(v_id, u_copy);
                try queue.append(allocator, v_id);
            }
        }

        if (!prev.contains(dst_id)) break; // No augmenting path

        // Find bottleneck
        var bottleneck: f64 = std.math.floatMax(f64);
        var v_id = dst_id;
        while (!std.mem.eql(u8, v_id, src_id)) {
            const u_id = prev.get(v_id).?;
            const cap_key = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ u_id, v_id });
            defer allocator.free(cap_key);
            const cap_val = capacity.get(cap_key) orelse 0;
            bottleneck = @min(bottleneck, cap_val);
            v_id = u_id;
        }

        // Augment flow along path
        v_id = dst_id;
        while (!std.mem.eql(u8, v_id, src_id)) {
            const u_id = prev.get(v_id).?;

            const forward_key = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ u_id, v_id });
            defer allocator.free(forward_key); // Key already exists in map, free our copy
            const forward_cap = capacity.get(forward_key).?;
            try capacity.put(forward_key, forward_cap - bottleneck);

            const backward_key = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ v_id, u_id });
            defer allocator.free(backward_key); // Key already exists in map, free our copy
            const backward_cap = capacity.get(backward_key) orelse 0;
            try capacity.put(backward_key, backward_cap + bottleneck);

            v_id = u_id;
        }

        total_flow += bottleneck;
    }

    // Build residual capacity map
    var residual = std.StringHashMap(f64).init(allocator);
    var cap_it = capacity.iterator();
    while (cap_it.next()) |entry| {
        const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
        try residual.put(key_copy, entry.value_ptr.*);
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

    graph.edges_mutex.lock();
    for (graph.edges.items) |edge| {
        var u_id: []const u8 = undefined;
        var v_id: []const u8 = undefined;
        var c: f64 = 1.0;

        switch (edge.*) {
            .basic => |basic| {
                u_id = basic.parent.id;
                v_id = basic.child.id;
            },
            .weighted => |weighted| {
                u_id = weighted.basic.parent.id;
                v_id = weighted.basic.child.id;
                c = weighted.weight;
            },
            .directed => |directed| {
                u_id = directed.basic.parent.id;
                v_id = directed.basic.child.id;
            },
            .directed_weighted => |dw| {
                u_id = dw.weighted.basic.parent.id;
                v_id = dw.weighted.basic.child.id;
                c = dw.weighted.weight;
            },
        }

        if (edge.* == .directed or edge.* == .directed_weighted) {
            try AddEdge.call(u_id, v_id, c, &adj, allocator);
        } else {
            try AddEdge.call(u_id, v_id, c, &adj, allocator);
            try AddEdge.call(v_id, u_id, c, &adj, allocator);
        }
    }
    graph.edges_mutex.unlock();

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

            while (queue.items.len > 0) {
                const u = queue.orderedRemove(0);
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
                // Keys are pre-populated, so put on existing key shouldn't allocate
                iters.put(u, i + 1) catch |err| {
                    std.debug.panic("Unexpected error in DFS iter update: {}", .{err});
                };

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
