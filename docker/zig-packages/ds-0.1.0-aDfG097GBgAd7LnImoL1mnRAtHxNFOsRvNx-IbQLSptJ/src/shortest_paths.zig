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
    defer {
        var it = prev.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        prev.deinit();
    }

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

        // Find vertex by ID
        var vtx: ?*graph_core.Vertex(T) = null;
        for (graph.getVertices()) |v| {
            if (std.mem.eql(u8, v.id, item.id)) {
                vtx = v;
                break;
            }
        }
        if (vtx == null) continue;

        const cur_dist = dist.get(item.id).?;
        if (item.cost > cur_dist) continue;

        // Explore edges
        for (graph.getEdges()) |edge| {
            var from: ?*graph_core.Vertex(T) = null;
            var to: ?*graph_core.Vertex(T) = null;
            var weight: f64 = 1.0;

            if (edge.getWeight()) |w| weight = w;

            if (edge.isDirected()) {
                from = edge.getParent();
                to = edge.getChild();
                if (from == null or !std.mem.eql(u8, from.?.id, vtx.?.id)) continue;
            } else {
                const vertices = edge.getVertices();
                if (std.mem.eql(u8, vertices[0].id, vtx.?.id)) {
                    from = vertices[0];
                    to = vertices[1];
                } else if (std.mem.eql(u8, vertices[1].id, vtx.?.id)) {
                    from = vertices[1];
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

    // Reconstruct path
    var path_nodes: std.ArrayListUnmanaged([]const u8) = .{};
    defer path_nodes.deinit(allocator);

    var current = dst.id;
    while (true) {
        try path_nodes.append(allocator, try allocator.dupe(u8, current));
        if (std.mem.eql(u8, current, src.id)) break;
        const p = prev.get(current) orelse break;
        current = p;
    }

    // Reverse path
    std.mem.reverse([]const u8, path_nodes.items);

    // Move to result
    for (path_nodes.items) |node| {
        try result.nodes.append(allocator, node);
    }
    result.cost = final_dist;

    return result;
}

/// Heuristic function type for A* - properly typed to take vertex pointers
pub fn HeuristicFn(comptime T: type) type {
    return *const fn (a: *graph_core.Vertex(T), b: *graph_core.Vertex(T)) f64;
}

/// Legacy alias for backwards compatibility - deprecated, use HeuristicFn instead
pub const Heuristic = *const fn (a: *anyopaque, b: *anyopaque) f64;

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
    defer {
        var it = prev.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        prev.deinit();
    }

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

        // Find current vertex
        var vtx: ?*graph_core.Vertex(T) = null;
        for (graph.getVertices()) |v| {
            if (std.mem.eql(u8, v.id, item.id)) {
                vtx = v;
                break;
            }
        }
        if (vtx == null) continue;

        // Explore neighbors through edges
        for (vtx.?.getEdges()) |edge| {
            var neighbor: ?*graph_core.Vertex(T) = null;
            var weight: f64 = 1.0;

            if (edge.getWeight()) |w| weight = w;

            if (edge.isDirected()) {
                if (edge.getParent()) |parent| {
                    if (std.mem.eql(u8, parent.id, vtx.?.id)) {
                        neighbor = edge.getChild();
                    }
                }
            } else {
                const vertices = edge.getVertices();
                if (std.mem.eql(u8, vertices[0].id, vtx.?.id)) {
                    neighbor = vertices[1];
                } else if (std.mem.eql(u8, vertices[1].id, vtx.?.id)) {
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

    var path_nodes: std.ArrayListUnmanaged([]const u8) = .{};
    defer path_nodes.deinit(allocator);

    var current = dst.id;
    while (true) {
        try path_nodes.append(allocator, try allocator.dupe(u8, current));
        if (std.mem.eql(u8, current, src.id)) break;
        const p = prev.get(current) orelse break;
        current = p;
    }

    std.mem.reverse([]const u8, path_nodes.items);

    for (path_nodes.items) |node| {
        try result.nodes.append(allocator, node);
    }
    result.cost = dist.get(dst.id).?;

    return result;
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

    // Explore neighbors
    for (graph.getEdges()) |edge| {
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
    defer {
        var it = prev.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        prev.deinit();
    }

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

    // Reconstruct path
    var path_nodes: std.ArrayListUnmanaged([]const u8) = .{};
    defer path_nodes.deinit(allocator);

    var current = dst.id;
    while (true) {
        try path_nodes.append(allocator, try allocator.dupe(u8, current));
        if (std.mem.eql(u8, current, src.id)) break;
        const p = prev.get(current) orelse break;
        current = p;
    }

    std.mem.reverse([]const u8, path_nodes.items);

    for (path_nodes.items) |node| {
        try result.nodes.append(allocator, node);
    }
    result.cost = final_dist;

    return result;
}

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
        var result = Path.init(self.allocator);
        errdefer result.deinit();

        const final_dist = self.distances.get(dst_id) orelse return result;
        if (std.math.isInf(final_dist)) return result;

        var path_nodes: std.ArrayListUnmanaged([]const u8) = .{};
        defer path_nodes.deinit(self.allocator);

        var current = dst_id;
        while (true) {
            try path_nodes.append(self.allocator, try self.allocator.dupe(u8, current));
            if (std.mem.eql(u8, current, src_id)) break;
            const p = self.prev.get(current) orelse break;
            current = p;
        }

        std.mem.reverse([]const u8, path_nodes.items);

        for (path_nodes.items) |node| {
            try result.nodes.append(self.allocator, node);
        }
        result.cost = final_dist;

        return result;
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
    errdefer {
        var it = prev.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        prev.deinit();
    }

    // Initialize distances
    for (graph.getVertices()) |v| {
        try dist.put(v.id, std.math.inf(f64));
    }
    try dist.put(src.id, 0.0);

    const vertices = graph.getVertices();
    const n = vertices.len;

    // Relax all edges |V| - 1 times
    for (0..n - 1) |_| {
        for (graph.getEdges()) |edge| {
            var u_id: []const u8 = undefined;
            var v_id: []const u8 = undefined;
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
pub const FloydWarshallResult = struct {
    /// Distance matrix indexed by vertex ID pairs "u->v"
    distances: std.StringHashMap(f64),
    /// Next hop matrix for path reconstruction
    next: std.StringHashMap([]const u8),
    has_negative_cycle: bool,
    allocator: Allocator,

    pub fn deinit(self: *FloydWarshallResult) void {
        var it = self.distances.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.distances.deinit();

        var next_it = self.next.iterator();
        while (next_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.next.deinit();
    }

    /// Get distance between two vertices.
    pub fn getDistance(self: *FloydWarshallResult, u: []const u8, v: []const u8) !?f64 {
        const key = try std.fmt.allocPrint(self.allocator, "{s}->{s}", .{ u, v });
        defer self.allocator.free(key);
        return self.distances.get(key);
    }
};

/// Floyd-Warshall all-pairs shortest paths algorithm.
/// Time complexity: O(V³)
/// Space complexity: O(V²)
pub fn floydWarshall(
    comptime T: type,
    graph: *Graph(T),
    allocator: Allocator,
) !FloydWarshallResult {
    var dist = std.StringHashMap(f64).init(allocator);
    errdefer {
        var it = dist.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        dist.deinit();
    }

    var next = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = next.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        next.deinit();
    }

    const vertices = graph.getVertices();

    // Initialize distances
    for (vertices) |u| {
        for (vertices) |v| {
            const key = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ u.id, v.id });
            if (std.mem.eql(u8, u.id, v.id)) {
                try dist.put(key, 0.0);
            } else {
                try dist.put(key, std.math.inf(f64));
            }
        }
    }

    // Initialize from edges
    for (graph.getEdges()) |edge| {
        var weight: f64 = 1.0;
        if (edge.getWeight()) |w| weight = w;

        if (edge.isDirected()) {
            const parent = edge.getParent() orelse continue;
            const child = edge.getChild() orelse continue;
            const key = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ parent.id, child.id });
            defer allocator.free(key);

            const current = dist.get(key) orelse std.math.inf(f64);
            if (weight < current) {
                // Update existing key's value
                try dist.put(key, weight);
                const next_key = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ parent.id, child.id });
                if (next.fetchRemove(next_key)) |removed| {
                    allocator.free(removed.key);
                    allocator.free(removed.value);
                }
                try next.put(next_key, try allocator.dupe(u8, child.id));
            }
        } else {
            // Undirected: both directions
            const verts = edge.getVertices();
            const key1 = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ verts[0].id, verts[1].id });
            defer allocator.free(key1);
            const key2 = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ verts[1].id, verts[0].id });
            defer allocator.free(key2);

            const current1 = dist.get(key1) orelse std.math.inf(f64);
            if (weight < current1) {
                try dist.put(key1, weight);
                const next_key1 = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ verts[0].id, verts[1].id });
                if (next.fetchRemove(next_key1)) |removed| {
                    allocator.free(removed.key);
                    allocator.free(removed.value);
                }
                try next.put(next_key1, try allocator.dupe(u8, verts[1].id));
            }

            const current2 = dist.get(key2) orelse std.math.inf(f64);
            if (weight < current2) {
                try dist.put(key2, weight);
                const next_key2 = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ verts[1].id, verts[0].id });
                if (next.fetchRemove(next_key2)) |removed| {
                    allocator.free(removed.key);
                    allocator.free(removed.value);
                }
                try next.put(next_key2, try allocator.dupe(u8, verts[0].id));
            }
        }
    }

    // Floyd-Warshall main loop
    for (vertices) |k| {
        for (vertices) |i| {
            for (vertices) |j| {
                const ik_key = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ i.id, k.id });
                defer allocator.free(ik_key);
                const kj_key = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ k.id, j.id });
                defer allocator.free(kj_key);
                const ij_key = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ i.id, j.id });
                defer allocator.free(ij_key);

                const d_ik = dist.get(ik_key) orelse std.math.inf(f64);
                const d_kj = dist.get(kj_key) orelse std.math.inf(f64);
                const d_ij = dist.get(ij_key) orelse std.math.inf(f64);

                if (!std.math.isInf(d_ik) and !std.math.isInf(d_kj)) {
                    const new_dist = d_ik + d_kj;
                    if (new_dist < d_ij) {
                        try dist.put(ij_key, new_dist);
                        // Update next: next[i][j] = next[i][k]
                        const next_ik = next.get(ik_key);
                        if (next_ik) |n| {
                            const ij_next_key = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ i.id, j.id });
                            if (next.fetchRemove(ij_next_key)) |removed| {
                                allocator.free(removed.key);
                                allocator.free(removed.value);
                            }
                            try next.put(ij_next_key, try allocator.dupe(u8, n));
                        }
                    }
                }
            }
        }
    }

    // Check for negative cycles (negative values on diagonal)
    var has_negative_cycle = false;
    for (vertices) |v| {
        const key = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ v.id, v.id });
        defer allocator.free(key);
        const d = dist.get(key) orelse 0.0;
        if (d < 0) {
            has_negative_cycle = true;
            break;
        }
    }

    return FloydWarshallResult{
        .distances = dist,
        .next = next,
        .has_negative_cycle = has_negative_cycle,
        .allocator = allocator,
    };
}
