// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("graph.zig").Graph;
const graph_core = @import("graph_core.zig");

/// Result structure for traversal algorithms (BFS, DFS)
pub const TraversalResult = struct {
    order: std.ArrayListUnmanaged([]const u8), // Visit order (IDs)
    prev: std.StringHashMap([]const u8), // Predecessor map
    allocator: Allocator,

    pub fn init(allocator: Allocator) TraversalResult {
        return .{
            .order = .{},
            .prev = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TraversalResult) void {
        // Free all duplicated strings in order
        for (self.order.items) |id| {
            self.allocator.free(id);
        }
        self.order.deinit(self.allocator);

        // Free all duplicated strings in prev (keys and values)
        var it = self.prev.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.prev.deinit();
    }
};

/// Breadth-First Search from a starting vertex.
/// Complexity: O(V + E) where V is vertices and E is edges.
pub fn bfsFrom(comptime T: type, start: *graph_core.Vertex(T), allocator: Allocator) !TraversalResult {
    var result = TraversalResult.init(allocator);
    errdefer result.deinit();

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        // Free all duplicated keys in seen
        var seen_it = seen.iterator();
        while (seen_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        seen.deinit();
    }

    var queue: std.ArrayListUnmanaged(*graph_core.Vertex(T)) = .{};
    defer queue.deinit(allocator);

    const start_id = try allocator.dupe(u8, start.id);
    try seen.put(start_id, {});
    try queue.append(allocator, start);

    // Reusable neighbors list to avoid per-vertex allocation
    var neighbors: std.ArrayListUnmanaged(*graph_core.Vertex(T)) = .{};
    defer neighbors.deinit(allocator);

    var queue_front: usize = 0;
    while (queue_front < queue.items.len) {
        const v = queue.items[queue_front];
        queue_front += 1;
        const v_id = try allocator.dupe(u8, v.id);
        try result.order.append(allocator, v_id);

        // Collect neighbors through vertex's incident edges - O(degree of v)
        neighbors.clearRetainingCapacity();

        for (v.getEdges()) |edge| {
            if (edge.isDirected()) {
                // For directed edges, only traverse if v is the parent
                if (edge.getParent()) |parent| {
                    if (std.mem.eql(u8, parent.id, v.id)) {
                        if (edge.getChild()) |child| {
                            try neighbors.append(allocator, child);
                        }
                    }
                }
            } else {
                // For undirected edges, get the other endpoint
                const vertices = edge.getVertices();
                if (std.mem.eql(u8, vertices[0].id, v.id)) {
                    try neighbors.append(allocator, vertices[1]);
                } else if (std.mem.eql(u8, vertices[1].id, v.id)) {
                    try neighbors.append(allocator, vertices[0]);
                }
            }
        }

        // Sort neighbors by ID for deterministic ordering
        std.mem.sort(*graph_core.Vertex(T), neighbors.items, {}, struct {
            fn lessThan(_: void, a: *graph_core.Vertex(T), b: *graph_core.Vertex(T)) bool {
                return std.mem.lessThan(u8, a.id, b.id);
            }
        }.lessThan);

        for (neighbors.items) |nb| {
            if (!seen.contains(nb.id)) {
                const nb_id_for_seen = try allocator.dupe(u8, nb.id);
                try seen.put(nb_id_for_seen, {});

                const nb_id_for_prev = try allocator.dupe(u8, nb.id);
                const parent_id = try allocator.dupe(u8, v.id);
                try result.prev.put(nb_id_for_prev, parent_id);
                try queue.append(allocator, nb);
            }
        }
    }

    return result;
}

/// Depth-First Search (iterative) from a starting vertex.
/// Complexity: O(V + E) where V is vertices and E is edges.
pub fn dfsFrom(comptime T: type, start: *graph_core.Vertex(T), allocator: Allocator) !TraversalResult {
    var result = TraversalResult.init(allocator);
    errdefer result.deinit();

    var seen = std.StringHashMap(bool).init(allocator);
    defer {
        // Free all duplicated keys in seen
        var seen_it = seen.iterator();
        while (seen_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        seen.deinit();
    }

    var stack: std.ArrayListUnmanaged(*graph_core.Vertex(T)) = .{};
    defer stack.deinit(allocator);

    try stack.append(allocator, start);

    // Reusable neighbors list to avoid per-vertex allocation
    var neighbors: std.ArrayListUnmanaged(*graph_core.Vertex(T)) = .{};
    defer neighbors.deinit(allocator);

    while (stack.items.len > 0) {
        const v = stack.pop().?;
        if (seen.get(v.id)) |_| continue;

        try seen.put(try allocator.dupe(u8, v.id), true);
        const v_id = try allocator.dupe(u8, v.id);
        try result.order.append(allocator, v_id);

        // Collect neighbors from vertex edges
        neighbors.clearRetainingCapacity();

        for (v.getEdges()) |edge| {
            if (edge.isDirected()) {
                if (edge.getParent()) |parent| {
                    if (std.mem.eql(u8, parent.id, v.id)) {
                        if (edge.getChild()) |child| {
                            try neighbors.append(allocator, child);
                        }
                    }
                }
            } else {
                const vertices = edge.getVertices();
                if (std.mem.eql(u8, vertices[0].id, v.id)) {
                    try neighbors.append(allocator, vertices[1]);
                } else if (std.mem.eql(u8, vertices[1].id, v.id)) {
                    try neighbors.append(allocator, vertices[0]);
                }
            }
        }

        // Sort descending so smallest ID is processed first (LIFO stack)
        std.mem.sort(*graph_core.Vertex(T), neighbors.items, {}, struct {
            fn lessThan(_: void, lhs: *graph_core.Vertex(T), rhs: *graph_core.Vertex(T)) bool {
                return std.mem.lessThan(u8, rhs.id, lhs.id); // Reverse for stack
            }
        }.lessThan);

        for (neighbors.items) |nb| {
            if (!seen.contains(nb.id)) {
                if (!result.prev.contains(nb.id)) {
                    const nb_id = try allocator.dupe(u8, nb.id);
                    const parent_id = try allocator.dupe(u8, v.id);
                    try result.prev.put(nb_id, parent_id);
                }
                try stack.append(allocator, nb);
            }
        }
    }

    return result;
}

/// Topological sort result
pub const TopoResult = struct {
    order: std.ArrayListUnmanaged([]const u8),
    is_acyclic: bool,
    allocator: Allocator,

    pub fn init(allocator: Allocator) TopoResult {
        return .{
            .order = .{},
            .is_acyclic = true,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TopoResult) void {
        for (self.order.items) |id| {
            self.allocator.free(id);
        }
        self.order.deinit(self.allocator);
    }
};

/// Topological sort using Kahn's algorithm (in-degree based)
pub fn topoKahn(comptime T: type, graph: *Graph(T), allocator: Allocator) !TopoResult {
    var result = TopoResult.init(allocator);
    errdefer result.deinit();

    var indegree = std.StringHashMap(usize).init(allocator);
    defer indegree.deinit();

    var adj = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator);
    defer {
        var it = adj.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        adj.deinit();
    }

    // Initialize in-degrees
    for (graph.getVertices()) |v| {
        try indegree.put(v.id, 0);
    }

    // Build adjacency list and calculate in-degrees
    for (graph.getEdges()) |edge| {
        if (edge.isDirected()) {
            if (edge.getParent()) |parent| {
                if (edge.getChild()) |child| {
                    const entry = indegree.getPtr(child.id).?;
                    entry.* += 1;

                    const adj_entry = try adj.getOrPut(parent.id);
                    if (!adj_entry.found_existing) {
                        adj_entry.value_ptr.* = .{};
                    }
                    try adj_entry.value_ptr.append(allocator, child.id);
                }
            }
        }
    }

    // Collect vertices with in-degree 0
    var queue: std.ArrayListUnmanaged([]const u8) = .{};
    defer queue.deinit(allocator);

    var it = indegree.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == 0) {
            try queue.append(allocator, entry.key_ptr.*);
        }
    }

    // Sort for deterministic order
    std.mem.sort([]const u8, queue.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var processed: usize = 0;
    while (processed < queue.items.len) {
        const u = queue.items[processed];
        processed += 1;

        const order_id = try allocator.dupe(u8, u);
        try result.order.append(allocator, order_id);

        if (adj.get(u)) |neighbors| {
            for (neighbors.items) |v| {
                const deg = indegree.getPtr(v).?;
                deg.* -= 1;
                if (deg.* == 0) {
                    try queue.append(allocator, v);
                }
            }
        }
    }

    result.is_acyclic = result.order.items.len == indegree.count();
    return result;
}

/// Topological sort using iterative DFS with explicit frame stack (SEC-018).
pub fn topoDFS(comptime T: type, graph: *Graph(T), allocator: Allocator) !TopoResult {
    var result = TopoResult.init(allocator);
    errdefer result.deinit();

    const WHITE: u8 = 0;
    const GRAY: u8 = 1;
    const BLACK: u8 = 2;

    var color = std.StringHashMap(u8).init(allocator);
    defer color.deinit();

    var adj = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator);
    defer {
        var it = adj.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        adj.deinit();
    }

    // Build adjacency list for directed edges
    for (graph.getEdges()) |edge| {
        if (edge.isDirected()) {
            if (edge.getParent()) |parent| {
                if (edge.getChild()) |child| {
                    const adj_entry = try adj.getOrPut(parent.id);
                    if (!adj_entry.found_existing) {
                        adj_entry.value_ptr.* = .{};
                    }
                    try adj_entry.value_ptr.append(allocator, child.id);
                }
            }
        }
    }

    var stack_order: std.ArrayListUnmanaged([]const u8) = .{};
    defer stack_order.deinit(allocator);

    // Iterative DFS using an explicit frame stack.
    // Each frame holds the vertex ID, its neighbors list, and the
    // current neighbor index being processed.
    const Frame = struct {
        vertex_id: []const u8,
        neighbors: []const []const u8, // borrowed from adj map
        neighbor_idx: usize,
    };

    var frame_stack: std.ArrayListUnmanaged(Frame) = .{};
    defer frame_stack.deinit(allocator);

    var acyclic = true;

    for (graph.getVertices()) |v| {
        const v_color = color.get(v.id) orelse WHITE;
        if (v_color != WHITE) continue;

        // Push initial frame
        try color.put(v.id, GRAY);
        const root_neighbors = if (adj.get(v.id)) |n| n.items else &[_][]const u8{};
        try frame_stack.append(allocator, .{
            .vertex_id = v.id,
            .neighbors = root_neighbors,
            .neighbor_idx = 0,
        });

        while (frame_stack.items.len > 0) {
            const frame = &frame_stack.items[frame_stack.items.len - 1];

            // Process neighbors starting from where we left off
            var pushed_child = false;
            while (frame.neighbor_idx < frame.neighbors.len) {
                const w = frame.neighbors[frame.neighbor_idx];
                const w_color = color.get(w) orelse WHITE;

                if (w_color == WHITE) {
                    // "Recurse" into w: mark gray and push a new frame
                    frame.neighbor_idx += 1;
                    try color.put(w, GRAY);
                    const w_neighbors = if (adj.get(w)) |n| n.items else &[_][]const u8{};
                    try frame_stack.append(allocator, .{
                        .vertex_id = w,
                        .neighbors = w_neighbors,
                        .neighbor_idx = 0,
                    });
                    pushed_child = true;
                    break;
                } else if (w_color == GRAY) {
                    // Back edge detected: cycle found
                    acyclic = false;
                    break;
                }
                frame.neighbor_idx += 1;
            }

            if (!acyclic) break;
            if (pushed_child) continue;

            // All neighbors processed - post-order: mark BLACK and record
            const finished_id = frame_stack.pop().?.vertex_id;
            try color.put(finished_id, BLACK);
            try stack_order.append(allocator, finished_id);
        }

        // Clear frame stack on cycle detection (early exit)
        if (!acyclic) {
            frame_stack.clearRetainingCapacity();
            break;
        }
    }

    // Reverse the order
    std.mem.reverse([]const u8, stack_order.items);
    for (stack_order.items) |id| {
        const dup_id = try allocator.dupe(u8, id);
        try result.order.append(allocator, dup_id);
    }

    result.is_acyclic = acyclic;
    return result;
}

/// Detect cycles in a directed graph
pub fn cycleDetectDirected(comptime T: type, graph: *Graph(T), allocator: Allocator) !bool {
    var topo = try topoDFS(T, graph, allocator);
    defer topo.deinit();
    return !topo.is_acyclic;
}

/// Detect cycles in an undirected graph using iterative DFS with explicit
/// frame stack (SEC-018).
pub fn cycleDetectUndirected(comptime T: type, graph: *Graph(T), allocator: Allocator) !bool {
    var visited = std.StringHashMap(bool).init(allocator);
    defer visited.deinit();

    var adj = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator);
    defer {
        var it = adj.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        adj.deinit();
    }

    // Build adjacency list for undirected edges
    for (graph.getEdges()) |edge| {
        if (!edge.isDirected()) {
            const vertices = edge.getVertices();
            const a = vertices[0].id;
            const b = vertices[1].id;

            const entry_a = try adj.getOrPut(a);
            if (!entry_a.found_existing) {
                entry_a.value_ptr.* = .{};
            }
            try entry_a.value_ptr.append(allocator, b);

            const entry_b = try adj.getOrPut(b);
            if (!entry_b.found_existing) {
                entry_b.value_ptr.* = .{};
            }
            try entry_b.value_ptr.append(allocator, a);
        }
    }

    // Iterative DFS using an explicit frame stack.
    // Each frame holds the vertex ID, its parent (for back-edge detection),
    // its neighbors list, and the current neighbor index.
    const Frame = struct {
        vertex_id: []const u8,
        parent_id: ?[]const u8,
        neighbors: []const []const u8, // borrowed from adj map
        neighbor_idx: usize,
    };

    var frame_stack: std.ArrayListUnmanaged(Frame) = .{};
    defer frame_stack.deinit(allocator);

    var has_cycle = false;

    var it = adj.keyIterator();
    while (it.next()) |key| {
        if (visited.contains(key.*)) continue;

        // Push initial frame for this connected component
        try visited.put(key.*, true);
        const root_neighbors = if (adj.get(key.*)) |n| n.items else &[_][]const u8{};
        try frame_stack.append(allocator, .{
            .vertex_id = key.*,
            .parent_id = null,
            .neighbors = root_neighbors,
            .neighbor_idx = 0,
        });

        while (frame_stack.items.len > 0) {
            const frame = &frame_stack.items[frame_stack.items.len - 1];

            // Process neighbors starting from where we left off
            var pushed_child = false;
            while (frame.neighbor_idx < frame.neighbors.len) {
                const v = frame.neighbors[frame.neighbor_idx];

                if (!visited.contains(v)) {
                    // Tree edge: "recurse" into v
                    frame.neighbor_idx += 1;
                    try visited.put(v, true);
                    const v_neighbors = if (adj.get(v)) |n| n.items else &[_][]const u8{};
                    try frame_stack.append(allocator, .{
                        .vertex_id = v,
                        .parent_id = frame.vertex_id,
                        .neighbors = v_neighbors,
                        .neighbor_idx = 0,
                    });
                    pushed_child = true;
                    break;
                } else if (frame.parent_id == null or !std.mem.eql(u8, v, frame.parent_id.?)) {
                    // Back edge to a visited non-parent vertex: cycle detected
                    has_cycle = true;
                    break;
                }
                frame.neighbor_idx += 1;
            }

            if (has_cycle) break;
            if (pushed_child) continue;

            // All neighbors processed - pop this frame
            _ = frame_stack.pop();
        }

        // Clear frame stack on cycle detection (early exit)
        if (has_cycle) {
            frame_stack.clearRetainingCapacity();
            break;
        }
    }

    return has_cycle;
}

/// Multi-source BFS returning distance map.
/// Complexity: O(V + E) where V is vertices and E is edges.
pub fn multiSourceBFS(comptime T: type, graph: *Graph(T), sources: []const *graph_core.Vertex(T), allocator: Allocator) !std.StringHashMap(usize) {
    _ = graph; // Graph not needed - we traverse via vertex edges

    var dist = std.StringHashMap(usize).init(allocator);
    errdefer dist.deinit();

    var queue: std.ArrayListUnmanaged(*graph_core.Vertex(T)) = .{};
    defer queue.deinit(allocator);

    for (sources) |s| {
        try dist.put(s.id, 0);
        try queue.append(allocator, s);
    }

    var idx: usize = 0;
    while (idx < queue.items.len) : (idx += 1) {
        const u = queue.items[idx];
        const u_dist = dist.get(u.id).?;

        // Iterate over vertex's incident edges - O(degree of u)
        for (u.getEdges()) |edge| {
            if (edge.isDirected()) {
                // For directed edges, only traverse if u is the parent
                if (edge.getParent()) |parent| {
                    if (std.mem.eql(u8, parent.id, u.id)) {
                        if (edge.getChild()) |child| {
                            if (!dist.contains(child.id)) {
                                try dist.put(child.id, u_dist + 1);
                                try queue.append(allocator, child);
                            }
                        }
                    }
                }
            } else {
                // For undirected edges, get the other endpoint
                const vertices = edge.getVertices();
                if (std.mem.eql(u8, vertices[0].id, u.id)) {
                    if (!dist.contains(vertices[1].id)) {
                        try dist.put(vertices[1].id, u_dist + 1);
                        try queue.append(allocator, vertices[1]);
                    }
                } else if (std.mem.eql(u8, vertices[1].id, u.id)) {
                    if (!dist.contains(vertices[0].id)) {
                        try dist.put(vertices[0].id, u_dist + 1);
                        try queue.append(allocator, vertices[0]);
                    }
                }
            }
        }
    }

    return dist;
}
