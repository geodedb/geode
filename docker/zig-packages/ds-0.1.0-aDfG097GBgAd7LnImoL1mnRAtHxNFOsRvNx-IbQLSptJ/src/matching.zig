// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("graph.zig").Graph;
const graph_core = @import("graph_core.zig");

/// BipartiteMatchingResult holds the result of bipartite matching.
pub const BipartiteMatchingResult = struct {
    /// Matching map from U to V (u_id -> v_id)
    matching: std.StringHashMap([]const u8),
    /// Size of the matching
    size: usize,
    allocator: Allocator,

    pub fn deinit(self: *BipartiteMatchingResult) void {
        var key_it = self.matching.keyIterator();
        while (key_it.next()) |key| {
            self.allocator.free(key.*);
        }
        var val_it = self.matching.valueIterator();
        while (val_it.next()) |val| {
            self.allocator.free(val.*);
        }
        self.matching.deinit();
    }
};

/// hopcroftKarp implements Hopcroft-Karp maximum bipartite matching.
/// Expects bipartite sets U and V; edges must be between sets.
/// Returns matching as map[u]=v and size.
pub fn hopcroftKarp(
    comptime T: type,
    graph: *Graph(T),
    U: []const *graph_core.Vertex(T),
    V: []const *graph_core.Vertex(T),
    allocator: Allocator,
) !BipartiteMatchingResult {
    // Build sets for quick lookup
    var u_set = std.StringHashMap(void).init(allocator);
    defer u_set.deinit();

    var v_set = std.StringHashMap(void).init(allocator);
    defer v_set.deinit();

    for (U) |u| {
        try u_set.put(u.id, {});
    }

    for (V) |v| {
        try v_set.put(v.id, {});
    }

    // Build adjacency list (only edges between U and V)
    var adj = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator);
    defer {
        var it = adj.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |id| {
                allocator.free(id);
            }
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        adj.deinit();
    }

    graph.edges_mutex.lock();
    for (graph.edges.items) |edge| {
        var a_id: []const u8 = undefined;
        var b_id: []const u8 = undefined;

        switch (edge.*) {
            .basic => |basic| {
                a_id = basic.parent.id;
                b_id = basic.child.id;
            },
            .weighted => |weighted| {
                a_id = weighted.basic.parent.id;
                b_id = weighted.basic.child.id;
            },
            .directed => |directed| {
                a_id = directed.basic.parent.id;
                b_id = directed.basic.child.id;
            },
            .directed_weighted => |dw| {
                a_id = dw.weighted.basic.parent.id;
                b_id = dw.weighted.basic.child.id;
            },
        }

        // Add edge if it connects U to V
        if (u_set.contains(a_id) and v_set.contains(b_id)) {
            if (!adj.contains(a_id)) {
                const a_copy = try allocator.dupe(u8, a_id);
                try adj.put(a_copy, .{});
            }
            const b_copy = try allocator.dupe(u8, b_id);
            try adj.getPtr(a_id).?.append(allocator, b_copy);
        }

        // For undirected/other direction
        if (u_set.contains(b_id) and v_set.contains(a_id)) {
            if (!adj.contains(b_id)) {
                const b_copy = try allocator.dupe(u8, b_id);
                try adj.put(b_copy, .{});
            }
            const a_copy = try allocator.dupe(u8, a_id);
            try adj.getPtr(b_id).?.append(allocator, a_copy);
        }
    }
    graph.edges_mutex.unlock();

    // Sort adjacency lists for deterministic ordering
    var adj_it = adj.valueIterator();
    while (adj_it.next()) |list| {
        std.mem.sort([]const u8, list.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
    }

    // Initialize matching
    var pair_u = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = pair_u.valueIterator();
        while (it.next()) |val| {
            allocator.free(val.*);
        }
        pair_u.deinit();
    }

    var pair_v = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = pair_v.valueIterator();
        while (it.next()) |val| {
            allocator.free(val.*);
        }
        pair_v.deinit();
    }

    var dist = std.StringHashMap(i32).init(allocator);
    defer dist.deinit();

    const INF: i32 = 1 << 30;

    const BFS = struct {
        fn call(
            u_vertices: []const *graph_core.Vertex(T),
            adjacency: *std.StringHashMap(std.ArrayListUnmanaged([]const u8)),
            pair_u_map: *std.StringHashMap([]const u8),
            pair_v_map: *std.StringHashMap([]const u8),
            distances: *std.StringHashMap(i32),
            inf: i32,
            alloc: Allocator,
        ) !bool {
            var queue: std.ArrayListUnmanaged([]const u8) = .{};
            defer queue.deinit(alloc);

            for (u_vertices) |u| {
                const u_id = u.id;
                if (!pair_u_map.contains(u_id)) {
                    try distances.put(u_id, 0);
                    try queue.append(alloc, u_id);
                } else {
                    try distances.put(u_id, inf);
                }
            }

            try distances.put("", inf);

            while (queue.items.len > 0) {
                const u_id = queue.orderedRemove(0);
                const u_dist = distances.get(u_id).?;

                if (u_dist < distances.get("").?) {
                    const neighbors = adjacency.get(u_id) orelse continue;
                    for (neighbors.items) |v_id| {
                        const pair_u_id = pair_v_map.get(v_id) orelse "";
                        if (distances.get(pair_u_id).? == inf) {
                            try distances.put(pair_u_id, u_dist + 1);
                            try queue.append(alloc, pair_u_id);
                        }
                    }
                }
            }

            return distances.get("").? != inf;
        }
    };

    const DFS = struct {
        fn call(
            u_id: []const u8,
            adjacency: *std.StringHashMap(std.ArrayListUnmanaged([]const u8)),
            pair_u_map: *std.StringHashMap([]const u8),
            pair_v_map: *std.StringHashMap([]const u8),
            distances: *std.StringHashMap(i32),
            inf: i32,
            alloc: Allocator,
        ) !bool {
            if (u_id.len == 0) return true;

            const u_dist = distances.get(u_id).?;
            const neighbors = adjacency.get(u_id) orelse return false;

            for (neighbors.items) |v_id| {
                const pair_u_id = pair_v_map.get(v_id) orelse "";
                const pair_dist = distances.get(pair_u_id).?;

                if (pair_dist == u_dist + 1) {
                    if (try call(pair_u_id, adjacency, pair_u_map, pair_v_map, distances, inf, alloc)) {
                        // Update matching - use fetchPut to properly handle existing keys
                        const v_copy = try alloc.dupe(u8, v_id);
                        const u_id_copy = try alloc.dupe(u8, u_id);

                        // Update pair_v_map[v_id] = u_id
                        if (try pair_v_map.fetchPut(v_id, u_id_copy)) |old_entry| {
                            alloc.free(old_entry.value); // Free old value
                        }

                        // Update pair_u_map[u_id] = v_id
                        if (try pair_u_map.fetchPut(u_id, v_copy)) |old_entry| {
                            alloc.free(old_entry.value); // Free old value
                        }

                        return true;
                    }
                }
            }

            try distances.put(u_id, inf);
            return false;
        }
    };

    var matching: usize = 0;

    while (try BFS.call(U, &adj, &pair_u, &pair_v, &dist, INF, allocator)) {
        for (U) |u| {
            const u_id = u.id;
            if (!pair_u.contains(u_id)) {
                if (try DFS.call(u_id, &adj, &pair_u, &pair_v, &dist, INF, allocator)) {
                    matching += 1;
                }
            }
        }
    }

    // Build result matching
    var result_matching = std.StringHashMap([]const u8).init(allocator);
    var pair_u_it = pair_u.iterator();
    while (pair_u_it.next()) |entry| {
        const u_copy = try allocator.dupe(u8, entry.key_ptr.*);
        const v_copy = try allocator.dupe(u8, entry.value_ptr.*);
        try result_matching.put(u_copy, v_copy);
    }

    return BipartiteMatchingResult{
        .matching = result_matching,
        .size = matching,
        .allocator = allocator,
    };
}
