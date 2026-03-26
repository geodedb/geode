// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("graph.zig").Graph;
const graph_core = @import("graph_core.zig");
const graph_algorithms = @import("graph_algorithms.zig");

/// Path structure representing a route through the graph.
///
/// ## Allocator Ownership
///
/// The Path structure owns all memory allocated for node IDs. The allocator passed
/// to the algorithm function is stored and used for cleanup in `deinit()`. Always
/// call `deinit()` when done with the path to avoid memory leaks.
pub const Path = struct {
    nodes: std.ArrayListUnmanaged([]const u8),
    cost: f64,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Path {
        return .{
            .nodes = .{},
            .cost = 0.0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Path) void {
        for (self.nodes.items) |id| {
            self.allocator.free(id);
        }
        self.nodes.deinit(self.allocator);
    }

    pub fn isEmpty(self: *const Path) bool {
        return self.nodes.items.len == 0;
    }
};

/// Free all owned keys and values in a StringHashMap([]const u8), then deinit it.
/// Shared cleanup for prev-maps that own duplicated key/value memory.
pub fn deinitOwnedStringMap(allocator: Allocator, map: *std.StringHashMap([]const u8)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

/// Reconstruct path from prev map by walking from dst to src.
/// Shared helper used by Dijkstra, A*, DAG shortest path, and Bellman-Ford.
pub fn reconstructPath(allocator: Allocator, prev: *std.StringHashMap([]const u8), src_id: []const u8, dst_id: []const u8, cost: f64) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();

    var path_nodes: std.ArrayListUnmanaged([]const u8) = .{};
    defer path_nodes.deinit(allocator);

    var current = dst_id;
    while (true) {
        try path_nodes.append(allocator, try allocator.dupe(u8, current));
        if (std.mem.eql(u8, current, src_id)) break;
        const p = prev.get(current) orelse break;
        current = p;
    }

    std.mem.reverse([]const u8, path_nodes.items);

    for (path_nodes.items) |node| {
        try result.nodes.append(allocator, node);
    }
    result.cost = cost;

    return result;
}

/// Priority queue item for Dijkstra/A*
const PQItem = struct {
    id: []const u8,
    cost: f64,

    fn lessThan(_: void, a: PQItem, b: PQItem) std.math.Order {
        if (a.cost == b.cost) {
            return std.mem.order(u8, a.id, b.id);
        }
        if (a.cost < b.cost) return .lt;
        if (a.cost > b.cost) return .gt;
        return .eq;
    }
};

/// Dijkstra's shortest path algorithm (non-negative weights)
pub fn dijkstra(
    comptime T: type,
    graph: *Graph(T),
    src: *graph_core.Vertex(T),
    dst: *graph_core.Vertex(T),
    allocator: Allocator,
) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();

    var dist = std.StringHashMap(f64).init(allocator);
    defer dist.deinit();

    var prev = std.StringHashMap([]const u8).init(allocator);
    defer deinitOwnedStringMap(allocator, &prev);

    // Initialize distances
    for (graph.getVertices()) |v| {
        try dist.put(v.id, std.math.inf(f64));
    }
    try dist.put(src.id, 0.0);

    // Priority queue
    var pq = std.PriorityQueue(PQItem, void, PQItem.lessThan).init(allocator, {});
    defer pq.deinit();

    try pq.add(.{ .id = src.id, .cost = 0.0 });

    while (pq.removeOrNull()) |item| {
        if (std.mem.eql(u8, item.id, dst.id)) break;

        // Find vertex by ID (O(1) via hash index)
        const vtx = graph.findVertexById(item.id) orelse continue;

        const cur_dist = dist.get(item.id).?;
        if (item.cost > cur_dist) continue;

        // Explore incident edges only (O(degree) instead of O(E))
        for (vtx.getEdges()) |edge| {
            var to: ?*graph_core.Vertex(T) = null;
            var weight: f64 = 1.0;

            if (edge.getWeight()) |w| weight = w;

            if (edge.isDirected()) {
                const parent = edge.getParent();
                if (parent == null or !std.mem.eql(u8, parent.?.id, vtx.id)) continue;
                to = edge.getChild();
            } else {
                const vertices = edge.getVertices();
                if (std.mem.eql(u8, vertices[0].id, vtx.id)) {
                    to = vertices[1];
                } else if (std.mem.eql(u8, vertices[1].id, vtx.id)) {
                    to = vertices[0];
                } else {
                    continue;
                }
            }

            if (to == null) continue;

            const new_dist = cur_dist + weight;
            const old_dist = dist.get(to.?.id).?;

            if (new_dist < old_dist) {
                try dist.put(to.?.id, new_dist);

                // Free old key and value if they exist
                if (prev.fetchRemove(to.?.id)) |removed| {
                    allocator.free(removed.key);
                    allocator.free(removed.value);
                }
                const prev_id = try allocator.dupe(u8, item.id);
                try prev.put(try allocator.dupe(u8, to.?.id), prev_id);

                try pq.add(.{ .id = to.?.id, .cost = new_dist });
            }
        }
    }

    // Check if destination is reachable
    const final_dist = dist.get(dst.id).?;
    if (std.math.isInf(final_dist)) {
        return result; // Empty path
    }

    result.deinit();
    return reconstructPath(allocator, &prev, src.id, dst.id, final_dist);
}

/// Heuristic function type for A* - properly typed to take vertex pointers
pub fn HeuristicFn(comptime T: type) type {
    return *const fn (a: *graph_core.Vertex(T), b: *graph_core.Vertex(T)) f64;
}

/// A* pathfinding with heuristic
pub fn aStar(
    comptime T: type,
    graph: *Graph(T),
    src: *graph_core.Vertex(T),
    dst: *graph_core.Vertex(T),
    heuristic: HeuristicFn(T),
    allocator: Allocator,
) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();

    if (src == dst) {
        const id = try allocator.dupe(u8, src.id);
        try result.nodes.append(allocator, id);
        result.cost = 0.0;
        return result;
    }

    var dist = std.StringHashMap(f64).init(allocator);
    defer dist.deinit();

    var prev = std.StringHashMap([]const u8).init(allocator);
    defer deinitOwnedStringMap(allocator, &prev);

    var visited = std.StringHashMap(bool).init(allocator);
    defer visited.deinit();

    try dist.put(src.id, 0.0);

    const AStarItem = struct {
        id: []const u8,
        g: f64,
        f: f64,

        fn lessThan(_: void, a: @This(), b: @This()) std.math.Order {
            if (a.f == b.f) {
                if (a.g == b.g) {
                    return std.mem.order(u8, a.id, b.id);
                }
                if (a.g < b.g) return .lt;
                if (a.g > b.g) return .gt;
                return .eq;
            }
            if (a.f < b.f) return .lt;
            if (a.f > b.f) return .gt;
            return .eq;
        }
    };

    var pq = std.PriorityQueue(AStarItem, void, AStarItem.lessThan).init(allocator, {});
    defer pq.deinit();

    const h_start = heuristic(src, dst);
    try pq.add(.{ .id = src.id, .g = 0.0, .f = h_start });

    while (pq.removeOrNull()) |item| {
        if (visited.get(item.id)) |_| continue;
        try visited.put(item.id, true);

        if (std.mem.eql(u8, item.id, dst.id)) break;

        // Find current vertex (O(1) via hash index)
        const vtx = graph.findVertexById(item.id) orelse continue;

        // Explore neighbors through incident edges
        for (vtx.getEdges()) |edge| {
            var neighbor: ?*graph_core.Vertex(T) = null;
            var weight: f64 = 1.0;

            if (edge.getWeight()) |w| weight = w;

            if (edge.isDirected()) {
                if (edge.getParent()) |parent| {
                    if (std.mem.eql(u8, parent.id, vtx.id)) {
                        neighbor = edge.getChild();
                    }
                }
            } else {
                const vertices = edge.getVertices();
                if (std.mem.eql(u8, vertices[0].id, vtx.id)) {
                    neighbor = vertices[1];
                } else if (std.mem.eql(u8, vertices[1].id, vtx.id)) {
                    neighbor = vertices[0];
                }
            }

            if (neighbor == null) continue;
            if (visited.contains(neighbor.?.id)) continue;

            const new_g = item.g + weight;
            const old_dist = dist.get(neighbor.?.id) orelse std.math.inf(f64);

            if (new_g < old_dist) {
                try dist.put(neighbor.?.id, new_g);

                // Free old key and value if they exist
                if (prev.fetchRemove(neighbor.?.id)) |removed| {
                    allocator.free(removed.key);
                    allocator.free(removed.value);
                }
                const prev_id = try allocator.dupe(u8, item.id);
                try prev.put(try allocator.dupe(u8, neighbor.?.id), prev_id);

                const h = heuristic(neighbor.?, dst);
                try pq.add(.{ .id = neighbor.?.id, .g = new_g, .f = new_g + h });
            }
        }
    }

    // Reconstruct path
    if (!visited.contains(dst.id)) {
        return result; // Empty path
    }

    result.deinit();
    return reconstructPath(allocator, &prev, src.id, dst.id, dist.get(dst.id).?);
}

/// IDDFS - Iterative Deepening Depth-First Search
pub fn iddfs(
    comptime T: type,
    graph: *Graph(T),
    start: *graph_core.Vertex(T),
    goal_id: []const u8,
    max_depth: usize,
    allocator: Allocator,
) !Path {
    var limit: usize = 0;
    while (limit <= max_depth) : (limit += 1) {
        var visited = std.StringHashMap(bool).init(allocator);
        defer visited.deinit();

        var path: std.ArrayListUnmanaged([]const u8) = .{};
        defer path.deinit(allocator);

        if (try dfsDepthLimited(T, graph, start, goal_id, limit, &visited, &path, allocator)) {
            var result = Path.init(allocator);
            for (path.items) |id| {
                const dup = try allocator.dupe(u8, id);
                try result.nodes.append(allocator, dup);
            }
            result.cost = @floatFromInt(path.items.len - 1);
            return result;
        }
    }

    return Path.init(allocator); // Empty path
}

fn dfsDepthLimited(
    comptime T: type,
    graph: *Graph(T),
    current: *graph_core.Vertex(T),
    goal_id: []const u8,
    limit: usize,
    visited: *std.StringHashMap(bool),
    path: *std.ArrayListUnmanaged([]const u8),
    allocator: Allocator,
) !bool {
    try path.append(allocator, current.id);

    if (std.mem.eql(u8, current.id, goal_id)) {
        return true;
    }

    if (limit == 0) {
        _ = path.pop();
        return false;
    }

    try visited.put(current.id, true);

    // Explore incident edges only (O(degree) instead of O(E))
    for (current.getEdges()) |edge| {
        var next: ?*graph_core.Vertex(T) = null;

        if (edge.isDirected()) {
            if (edge.getParent()) |parent| {
                if (std.mem.eql(u8, parent.id, current.id)) {
                    next = edge.getChild();
                }
            }
        } else {
            const vertices = edge.getVertices();
            if (std.mem.eql(u8, vertices[0].id, current.id)) {
                next = vertices[1];
            } else if (std.mem.eql(u8, vertices[1].id, current.id)) {
                next = vertices[0];
            }
        }

        if (next == null) continue;
        if (visited.contains(next.?.id)) continue;

        if (try dfsDepthLimited(T, graph, next.?, goal_id, limit - 1, visited, path, allocator)) {
            return true;
        }
    }

    _ = path.pop();
    return false;
}

/// DAG shortest path using topological sort
pub fn dagShortestPath(
    comptime T: type,
    graph: *Graph(T),
    src: *graph_core.Vertex(T),
    dst: *graph_core.Vertex(T),
    allocator: Allocator,
) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();

    // Get topological order
    var topo = try graph_algorithms.topoKahn(T, graph, allocator);
    defer topo.deinit();

    if (!topo.is_acyclic) {
        return result; // Empty path for cyclic graph
    }

    var dist = std.StringHashMap(f64).init(allocator);
    defer dist.deinit();

    var prev = std.StringHashMap([]const u8).init(allocator);
    defer deinitOwnedStringMap(allocator, &prev);

    // Initialize distances
    for (topo.order.items) |id| {
        try dist.put(id, std.math.inf(f64));
    }
    try dist.put(src.id, 0.0);

    // Build adjacency with weights
    const EdgeInfo = struct { to: []const u8, w: f64 };
    var adj = std.StringHashMap(std.ArrayListUnmanaged(EdgeInfo)).init(allocator);
    defer {
        var it = adj.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        adj.deinit();
    }

    for (graph.getEdges()) |edge| {
        if (!edge.isDirected()) continue;

        const parent = edge.getParent() orelse continue;
        const child = edge.getChild() orelse continue;
        const weight = edge.getWeight() orelse 1.0;

        const entry = try adj.getOrPut(parent.id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{};
        }
        try entry.value_ptr.append(allocator, .{ .to = child.id, .w = weight });
    }

    // Relax edges in topological order
    for (topo.order.items) |u_id| {
        const du = dist.get(u_id).?;
        if (std.math.isInf(du)) continue;

        if (adj.get(u_id)) |neighbors| {
            for (neighbors.items) |ei| {
                const new_dist = du + ei.w;
                const old_dist = dist.get(ei.to).?;

                if (new_dist < old_dist) {
                    try dist.put(ei.to, new_dist);

                    // Free old key and value if they exist
                    if (prev.fetchRemove(ei.to)) |removed| {
                        allocator.free(removed.key);
                        allocator.free(removed.value);
                    }
                    const prev_id = try allocator.dupe(u8, u_id);
                    try prev.put(try allocator.dupe(u8, ei.to), prev_id);
                }
            }
        }
    }

    // Check if reachable
    const final_dist = dist.get(dst.id).?;
    if (std.math.isInf(final_dist)) {
        return result;
    }

    result.deinit();
    return reconstructPath(allocator, &prev, src.id, dst.id, final_dist);
}
