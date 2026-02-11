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

    const StrongConnect = struct {
        fn call(
            v: *graph_core.Vertex(T),
            current_index: *i32,
            current_stack: *std.ArrayListUnmanaged(*graph_core.Vertex(T)),
            stack_set: *std.StringHashMap(bool),
            indices: *std.StringHashMap(i32),
            low_link: *std.StringHashMap(i32),
            comps: *std.ArrayListUnmanaged(std.ArrayListUnmanaged([]const u8)),
            alloc: Allocator,
        ) !void {
            const vid = v.id;
            try indices.put(vid, current_index.*);
            try low_link.put(vid, current_index.*);
            current_index.* += 1;
            try current_stack.append(alloc, v);
            try stack_set.put(vid, true);

            // Get neighbors (directed out edges)
            var neighbors: std.ArrayListUnmanaged(*graph_core.Vertex(T)) = .{};
            defer neighbors.deinit(alloc);

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
                        // Treat undirected as bidirectional
                        if (b.parent == v) {
                            try neighbors.append(alloc, b.child);
                        } else if (b.child == v) {
                            try neighbors.append(alloc, b.parent);
                        }
                    },
                    .weighted => |w| {
                        // Treat undirected as bidirectional
                        if (w.basic.parent == v) {
                            try neighbors.append(alloc, w.basic.child);
                        } else if (w.basic.child == v) {
                            try neighbors.append(alloc, w.basic.parent);
                        }
                    },
                }
            }

            // Sort neighbors for deterministic ordering
            std.mem.sort(*graph_core.Vertex(T), neighbors.items, {}, struct {
                fn lessThan(_: void, lhs: *graph_core.Vertex(T), rhs: *graph_core.Vertex(T)) bool {
                    return std.mem.lessThan(u8, lhs.id, rhs.id);
                }
            }.lessThan);

            for (neighbors.items) |w| {
                const wid = w.id;
                if (!indices.contains(wid)) {
                    try call(w, current_index, current_stack, stack_set, indices, low_link, comps, alloc);
                    const w_low = low_link.get(wid).?;
                    const v_low = low_link.get(vid).?;
                    if (w_low < v_low) {
                        try low_link.put(vid, w_low);
                    }
                } else if (stack_set.get(wid) orelse false) {
                    const w_idx = indices.get(wid).?;
                    const v_low = low_link.get(vid).?;
                    if (w_idx < v_low) {
                        try low_link.put(vid, w_idx);
                    }
                }
            }

            // If v is a root node, pop the stack and create an SCC
            if (low_link.get(vid).? == indices.get(vid).?) {
                var comp: std.ArrayListUnmanaged([]const u8) = .{};
                while (true) {
                    const w_vert = current_stack.pop() orelse break;
                    const wid = w_vert.id;
                    try stack_set.put(wid, false);
                    const wid_copy = try alloc.dupe(u8, wid);
                    try comp.append(alloc, wid_copy);
                    if (std.mem.eql(u8, wid, vid)) break;
                }

                // Sort component
                std.mem.sort([]const u8, comp.items, {}, struct {
                    fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                        return std.mem.lessThan(u8, lhs, rhs);
                    }
                }.lessThan);

                try comps.append(alloc, comp);
            }
        }
    };

    graph.vertices_mutex.lock();
    const vertices = try allocator.dupe(*graph_core.Vertex(T), graph.vertices.items);
    graph.vertices_mutex.unlock();
    defer allocator.free(vertices);

    for (vertices) |v| {
        const vid = v.id;
        if (!idx_map.contains(vid)) {
            try StrongConnect.call(v, &index, &stack, &on_stack, &idx_map, &low_map, &components, allocator);
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

    const DFS = struct {
        fn call(
            v: *graph_core.Vertex(T),
            current_timer: *u32,
            discovery: *std.StringHashMap(u32),
            low_link: *std.StringHashMap(u32),
            par: *std.StringHashMap([]const u8),
            art_points: *std.StringHashMap(bool),
            bridges: *std.AutoHashMap([2][]const u8, void),
            alloc: Allocator,
        ) !void {
            const vid = v.id;
            current_timer.* += 1;
            try discovery.put(vid, current_timer.*);
            try low_link.put(vid, current_timer.*);
            var child_count: u32 = 0;

            for (v.edges.items) |edge| {
                // Get the other vertex (treat all edges as undirected)
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

                if (other == null) continue;
                const uid = other.?.id;

                if ((discovery.get(uid) orelse 0) == 0) {
                    // Tree edge
                    try par.put(uid, vid);
                    child_count += 1;
                    try call(other.?, current_timer, discovery, low_link, par, art_points, bridges, alloc);

                    const u_low = low_link.get(uid).?;
                    const v_low = low_link.get(vid).?;
                    if (u_low < v_low) {
                        try low_link.put(vid, u_low);
                    }

                    // Check for articulation point
                    const v_parent = par.get(vid);
                    if (v_parent == null and child_count > 1) {
                        try art_points.put(vid, true);
                    }
                    if (v_parent != null and u_low >= discovery.get(vid).?) {
                        try art_points.put(vid, true);
                    }

                    // Check for bridge
                    if (u_low > discovery.get(vid).?) {
                        var a = try alloc.dupe(u8, vid);
                        var b = try alloc.dupe(u8, uid);
                        if (std.mem.lessThan(u8, b, a)) {
                            const tmp = a;
                            a = b;
                            b = tmp;
                        }
                        try bridges.put([2][]const u8{ a, b }, {});
                    }
                } else if (!std.mem.eql(u8, uid, par.get(vid) orelse "")) {
                    // Back edge
                    const u_disc = discovery.get(uid).?;
                    const v_low = low_link.get(vid).?;
                    if (u_disc < v_low) {
                        try low_link.put(vid, u_disc);
                    }
                }
            }
        }
    };

    graph.vertices_mutex.lock();
    const vertices = try allocator.dupe(*graph_core.Vertex(T), graph.vertices.items);
    graph.vertices_mutex.unlock();
    defer allocator.free(vertices);

    for (vertices) |v| {
        const vid = v.id;
        if ((disc.get(vid) orelse 0) == 0) {
            try DFS.call(v, &timer, &disc, &low, &parent, &ap, &bridge_set, allocator);
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
