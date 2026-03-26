// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("graph.zig").Graph;
const graph_core = @import("graph_core.zig");

/// SCCResult holds the strongly connected components of a graph.
pub const SCCResult = struct {
    /// Each component is a list of vertex IDs sorted lexicographically.
    /// The outer list is sorted by the first ID in each component.
    components: std.ArrayListUnmanaged(std.ArrayListUnmanaged([]const u8)),
    allocator: Allocator,

    pub fn deinit(self: *SCCResult) void {
        for (self.components.items) |*comp| {
            for (comp.items) |id| {
                self.allocator.free(id);
            }
            comp.deinit(self.allocator);
        }
        self.components.deinit(self.allocator);
    }
};

/// sccTarjan computes strongly connected components using Tarjan's algorithm.
pub fn sccTarjan(comptime T: type, graph: *Graph(T), allocator: Allocator) !SCCResult {
    var index: i32 = 0;
    var stack: std.ArrayListUnmanaged(*graph_core.Vertex(T)) = .{};
    defer stack.deinit(allocator);

    var on_stack = std.StringHashMap(bool).init(allocator);
    defer on_stack.deinit();

    var idx_map = std.StringHashMap(i32).init(allocator);
    defer idx_map.deinit();

    var low_map = std.StringHashMap(i32).init(allocator);
    defer low_map.deinit();

    var components: std.ArrayListUnmanaged(std.ArrayListUnmanaged([]const u8)) = .{};
    errdefer {
        for (components.items) |*comp| {
            for (comp.items) |id| allocator.free(id);
            comp.deinit(allocator);
        }
        components.deinit(allocator);
    }

    // Iterative Tarjan's using an explicit frame stack (SEC-018).
    // Each frame holds the vertex, its sorted neighbor list, and the
    // current neighbor index being processed.
    const Frame = struct {
        vertex: *graph_core.Vertex(T),
        neighbors: std.ArrayListUnmanaged(*graph_core.Vertex(T)),
        neighbor_idx: usize,
    };

    var frame_stack: std.ArrayListUnmanaged(Frame) = .{};
    defer {
        for (frame_stack.items) |*f| f.neighbors.deinit(allocator);
        frame_stack.deinit(allocator);
    }

    // Helper to collect and sort neighbors for a vertex
    const getNeighbors = struct {
        fn call(v: *graph_core.Vertex(T), alloc: Allocator) !std.ArrayListUnmanaged(*graph_core.Vertex(T)) {
            var neighbors: std.ArrayListUnmanaged(*graph_core.Vertex(T)) = .{};
            for (v.edges.items) |edge| {
                switch (edge.*) {
                    .directed => |d| {
                        if (d.basic.parent == v) {
                            try neighbors.append(alloc, d.basic.child);
                        }
                    },
                    .directed_weighted => |dw| {
                        if (dw.weighted.basic.parent == v) {
                            try neighbors.append(alloc, dw.weighted.basic.child);
                        }
                    },
                    .basic => |b| {
                        if (b.parent == v) {
                            try neighbors.append(alloc, b.child);
                        } else if (b.child == v) {
                            try neighbors.append(alloc, b.parent);
                        }
                    },
                    .weighted => |w| {
                        if (w.basic.parent == v) {
                            try neighbors.append(alloc, w.basic.child);
                        } else if (w.basic.child == v) {
                            try neighbors.append(alloc, w.basic.parent);
                        }
                    },
                }
            }
            std.mem.sort(*graph_core.Vertex(T), neighbors.items, {}, struct {
                fn lessThan(_: void, lhs: *graph_core.Vertex(T), rhs: *graph_core.Vertex(T)) bool {
                    return std.mem.lessThan(u8, lhs.id, rhs.id);
                }
            }.lessThan);
            return neighbors;
        }
    }.call;

    graph.vertices_mutex.lock();
    const vertices = try allocator.dupe(*graph_core.Vertex(T), graph.vertices.items);
    graph.vertices_mutex.unlock();
    defer allocator.free(vertices);

    for (vertices) |root_v| {
        if (idx_map.contains(root_v.id)) continue;

        // Initialize root frame
        try idx_map.put(root_v.id, index);
        try low_map.put(root_v.id, index);
        index += 1;
        try stack.append(allocator, root_v);
        try on_stack.put(root_v.id, true);

        const root_neighbors = try getNeighbors(root_v, allocator);
        try frame_stack.append(allocator, .{
            .vertex = root_v,
            .neighbors = root_neighbors,
            .neighbor_idx = 0,
        });

        while (frame_stack.items.len > 0) {
            const frame = &frame_stack.items[frame_stack.items.len - 1];
            const v = frame.vertex;
            const vid = v.id;

            // Process neighbors starting from where we left off
            var pushed_child = false;
            while (frame.neighbor_idx < frame.neighbors.items.len) {
                const w = frame.neighbors.items[frame.neighbor_idx];
                const wid = w.id;

                if (!idx_map.contains(wid)) {
                    // "Recurse" into w: initialize it and push a new frame
                    frame.neighbor_idx += 1; // advance so we resume after this neighbor on return
                    try idx_map.put(wid, index);
                    try low_map.put(wid, index);
                    index += 1;
                    try stack.append(allocator, w);
                    try on_stack.put(wid, true);

                    const w_neighbors = try getNeighbors(w, allocator);
                    try frame_stack.append(allocator, .{
                        .vertex = w,
                        .neighbors = w_neighbors,
                        .neighbor_idx = 0,
                    });
                    pushed_child = true;
                    break;
                } else if (on_stack.get(wid) orelse false) {
                    const w_idx = idx_map.get(wid).?;
                    const v_low = low_map.get(vid).?;
                    if (w_idx < v_low) {
                        try low_map.put(vid, w_idx);
                    }
                }
                frame.neighbor_idx += 1;
            }

            if (pushed_child) continue;

            // All neighbors processed - do post-order work (SCC extraction)
            if (low_map.get(vid).? == idx_map.get(vid).?) {
                var comp: std.ArrayListUnmanaged([]const u8) = .{};
                while (true) {
                    const w_vert = stack.pop() orelse break;
                    const wid = w_vert.id;
                    try on_stack.put(wid, false);
                    const wid_copy = try allocator.dupe(u8, wid);
                    try comp.append(allocator, wid_copy);
                    if (std.mem.eql(u8, wid, vid)) break;
                }
                std.mem.sort([]const u8, comp.items, {}, struct {
                    fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                        return std.mem.lessThan(u8, lhs, rhs);
                    }
                }.lessThan);
                try components.append(allocator, comp);
            }

            // Pop this frame
            var finished_frame = frame_stack.pop().?;
            finished_frame.neighbors.deinit(allocator);

            // Propagate low_link to parent frame
            if (frame_stack.items.len > 0) {
                const parent_frame = &frame_stack.items[frame_stack.items.len - 1];
                const parent_vid = parent_frame.vertex.id;
                const child_low = low_map.get(vid).?;
                const parent_low = low_map.get(parent_vid).?;
                if (child_low < parent_low) {
                    try low_map.put(parent_vid, child_low);
                }
            }
        }
    }

    // Sort components by first element
    std.mem.sort(std.ArrayListUnmanaged([]const u8), components.items, {}, struct {
        fn lessThan(_: void, lhs: std.ArrayListUnmanaged([]const u8), rhs: std.ArrayListUnmanaged([]const u8)) bool {
            if (lhs.items.len == 0) return true;
            if (rhs.items.len == 0) return false;
            return std.mem.lessThan(u8, lhs.items[0], rhs.items[0]);
        }
    }.lessThan);

    return SCCResult{
        .components = components,
        .allocator = allocator,
    };
}

/// ArticulationResult holds articulation points and bridges.
pub const ArticulationResult = struct {
    /// Articulation points (vertices whose removal increases connected components)
    points: std.ArrayListUnmanaged([]const u8),
    /// Bridges (edges whose removal increases connected components)
    /// Each bridge is represented as [2][]const u8 with lexicographic ordering
    bridges: std.ArrayListUnmanaged([2][]const u8),
    allocator: Allocator,

    pub fn deinit(self: *ArticulationResult) void {
        for (self.points.items) |p| {
            self.allocator.free(p);
        }
        self.points.deinit(self.allocator);

        for (self.bridges.items) |b| {
            self.allocator.free(b[0]);
            self.allocator.free(b[1]);
        }
        self.bridges.deinit(self.allocator);
    }
};

/// articulationBridges computes articulation points and bridges for an undirected graph.
/// Directed edges are treated as undirected for this analysis.
pub fn articulationBridges(comptime T: type, graph: *Graph(T), allocator: Allocator) !ArticulationResult {
    var timer: u32 = 0;
    var disc = std.StringHashMap(u32).init(allocator);
    defer disc.deinit();

    var low = std.StringHashMap(u32).init(allocator);
    defer low.deinit();

    var parent = std.StringHashMap([]const u8).init(allocator);
    defer parent.deinit();

    var ap = std.StringHashMap(bool).init(allocator);
    defer ap.deinit();

    var bridge_set = std.AutoHashMap([2][]const u8, void).init(allocator);
    defer bridge_set.deinit();

    // Iterative DFS using an explicit frame stack (SEC-018).
    // Each frame holds the vertex, its neighbor list, the current edge index,
    // and the child_count (number of tree edges from this vertex).
    const ABFrame = struct {
        vertex: *graph_core.Vertex(T),
        neighbors: std.ArrayListUnmanaged(*graph_core.Vertex(T)),
        edge_idx: usize,
        child_count: u32,
    };

    // Helper to collect neighbors (treating all edges as undirected)
    const getOtherVertices = struct {
        fn call(v: *graph_core.Vertex(T), alloc: Allocator) !std.ArrayListUnmanaged(*graph_core.Vertex(T)) {
            var neighbors: std.ArrayListUnmanaged(*graph_core.Vertex(T)) = .{};
            for (v.edges.items) |edge| {
                var other: ?*graph_core.Vertex(T) = null;
                switch (edge.*) {
                    .basic => |b| {
                        if (b.parent == v) {
                            other = b.child;
                        } else if (b.child == v) {
                            other = b.parent;
                        }
                    },
                    .weighted => |w| {
                        if (w.basic.parent == v) {
                            other = w.basic.child;
                        } else if (w.basic.child == v) {
                            other = w.basic.parent;
                        }
                    },
                    .directed => |d| {
                        if (d.basic.parent == v) {
                            other = d.basic.child;
                        } else if (d.basic.child == v) {
                            other = d.basic.parent;
                        }
                    },
                    .directed_weighted => |dw| {
                        if (dw.weighted.basic.parent == v) {
                            other = dw.weighted.basic.child;
                        } else if (dw.weighted.basic.child == v) {
                            other = dw.weighted.basic.parent;
                        }
                    },
                }
                if (other) |o| try neighbors.append(alloc, o);
            }
            return neighbors;
        }
    }.call;

    var frame_stack: std.ArrayListUnmanaged(ABFrame) = .{};
    defer {
        for (frame_stack.items) |*f| f.neighbors.deinit(allocator);
        frame_stack.deinit(allocator);
    }

    // Track child_count per vertex (needed for articulation point check on return)
    var child_count_map = std.StringHashMap(u32).init(allocator);
    defer child_count_map.deinit();

    graph.vertices_mutex.lock();
    const vertices = try allocator.dupe(*graph_core.Vertex(T), graph.vertices.items);
    graph.vertices_mutex.unlock();
    defer allocator.free(vertices);

    for (vertices) |root_v| {
        if ((disc.get(root_v.id) orelse 0) != 0) continue;

        // Initialize root frame
        timer += 1;
        try disc.put(root_v.id, timer);
        try low.put(root_v.id, timer);

        const root_neighbors = try getOtherVertices(root_v, allocator);
        try frame_stack.append(allocator, .{
            .vertex = root_v,
            .neighbors = root_neighbors,
            .edge_idx = 0,
            .child_count = 0,
        });

        while (frame_stack.items.len > 0) {
            const frame = &frame_stack.items[frame_stack.items.len - 1];
            const v = frame.vertex;
            const vid = v.id;

            var pushed_child = false;
            while (frame.edge_idx < frame.neighbors.items.len) {
                const other = frame.neighbors.items[frame.edge_idx];
                const uid = other.id;

                if ((disc.get(uid) orelse 0) == 0) {
                    // Tree edge: "recurse" into other
                    try parent.put(uid, vid);
                    frame.child_count += 1;
                    frame.edge_idx += 1;

                    timer += 1;
                    try disc.put(uid, timer);
                    try low.put(uid, timer);

                    const other_neighbors = try getOtherVertices(other, allocator);
                    try frame_stack.append(allocator, .{
                        .vertex = other,
                        .neighbors = other_neighbors,
                        .edge_idx = 0,
                        .child_count = 0,
                    });
                    pushed_child = true;
                    break;
                } else if (!std.mem.eql(u8, uid, parent.get(vid) orelse "")) {
                    // Back edge
                    const u_disc = disc.get(uid).?;
                    const v_low = low.get(vid).?;
                    if (u_disc < v_low) {
                        try low.put(vid, u_disc);
                    }
                }
                frame.edge_idx += 1;
            }

            if (pushed_child) continue;

            // All edges processed - post-order: pop frame and propagate to parent
            const finished_child_count = frame.child_count;
            var finished_frame = frame_stack.pop().?;
            finished_frame.neighbors.deinit(allocator);

            if (frame_stack.items.len > 0) {
                // We are returning from processing uid=vid to parent
                const parent_frame = &frame_stack.items[frame_stack.items.len - 1];
                const parent_vid = parent_frame.vertex.id;

                const u_low = low.get(vid).?;
                const v_low_parent = low.get(parent_vid).?;
                if (u_low < v_low_parent) {
                    try low.put(parent_vid, u_low);
                }

                // Check for articulation point
                const v_parent = parent.get(parent_vid);
                if (v_parent == null and parent_frame.child_count > 1) {
                    try ap.put(parent_vid, true);
                }
                if (v_parent != null and u_low >= disc.get(parent_vid).?) {
                    try ap.put(parent_vid, true);
                }

                // Check for bridge
                if (u_low > disc.get(parent_vid).?) {
                    var a = try allocator.dupe(u8, parent_vid);
                    var b = try allocator.dupe(u8, vid);
                    if (std.mem.lessThan(u8, b, a)) {
                        const tmp = a;
                        a = b;
                        b = tmp;
                    }
                    try bridge_set.put([2][]const u8{ a, b }, {});
                }
            } else {
                // Root node: check if it's an articulation point (>1 tree children)
                if (finished_child_count > 1) {
                    try ap.put(vid, true);
                }
            }
        }
    }

    // Collect articulation points
    var points: std.ArrayListUnmanaged([]const u8) = .{};
    var ap_it = ap.iterator();
    while (ap_it.next()) |entry| {
        const id_copy = try allocator.dupe(u8, entry.key_ptr.*);
        try points.append(allocator, id_copy);
    }
    std.mem.sort([]const u8, points.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    // Collect bridges
    var bridges: std.ArrayListUnmanaged([2][]const u8) = .{};
    var bridge_it = bridge_set.keyIterator();
    while (bridge_it.next()) |bridge| {
        try bridges.append(allocator, bridge.*);
    }
    std.mem.sort([2][]const u8, bridges.items, {}, struct {
        fn lessThan(_: void, lhs: [2][]const u8, rhs: [2][]const u8) bool {
            const cmp0 = std.mem.order(u8, lhs[0], rhs[0]);
            if (cmp0 == .eq) {
                return std.mem.lessThan(u8, lhs[1], rhs[1]);
            }
            return cmp0 == .lt;
        }
    }.lessThan);

    return ArticulationResult{
        .points = points,
        .bridges = bridges,
        .allocator = allocator,
    };
}
