const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../gql/ast.zig");
const graph_exec = @import("../server/graph/exec.zig");

// Built-in graph algorithm functions for GQL
pub const BuiltinAlgorithms = struct {
    allocator: Allocator,
    graph: *graph_exec.GraphStorage,

    pub fn init(allocator: Allocator, graph: *graph_exec.GraphStorage) BuiltinAlgorithms {
        return .{
            .allocator = allocator,
            .graph = graph,
        };
    }

    // shortestPath() function - finds shortest path between two nodes
    pub fn shortestPath(
        self: *BuiltinAlgorithms,
        start_node: u64,
        end_node: u64,
        max_depth: ?u32,
        relationship_types: ?[]const []const u8,
        direction: graph_exec.Direction,
    ) !?graph_exec.Path {
        // BFS for unweighted shortest path
        var visited = std.AutoHashMap(u64, void).init(self.allocator);
        defer visited.deinit();

        var parent = std.AutoHashMap(u64, PathInfo).init(self.allocator);
        defer parent.deinit();

        const PathInfo = struct {
            node: u64,
            edge: ?u64,
        };

        var queue = std.ArrayList(QueueItem){};
        defer queue.deinit();

        const QueueItem = struct {
            node: u64,
            depth: u32,
        };

        try queue.append(.{ .node = start_node, .depth = 0 });
        try visited.put(start_node, {});

        var front: usize = 0;
        while (front < queue.items.len) : (front += 1) {
            const current = queue.items[front];

            if (current.node == end_node) {
                // Reconstruct path
                return try self.reconstructPath(start_node, end_node, &parent);
            }

            if (max_depth) |max| {
                if (current.depth >= max) continue;
            }

            // Get neighbors based on direction
            const neighbors = try self.getNeighbors(current.node, relationship_types, direction);
            defer self.allocator.free(neighbors);

            for (neighbors) |neighbor| {
                if (!visited.contains(neighbor.node)) {
                    try visited.put(neighbor.node, {});
                    try parent.put(neighbor.node, .{
                        .node = current.node,
                        .edge = neighbor.edge,
                    });
                    try queue.append(.{
                        .node = neighbor.node,
                        .depth = current.depth + 1,
                    });
                }
            }
        }

        return null; // No path found
    }

    // allShortestPaths() - finds all shortest paths between two nodes
    pub fn allShortestPaths(
        self: *BuiltinAlgorithms,
        start_node: u64,
        end_node: u64,
        max_depth: ?u32,
        relationship_types: ?[]const []const u8,
        direction: graph_exec.Direction,
    ) ![]graph_exec.Path {
        var paths = std.ArrayList(graph_exec.Path){};

        // Multi-source BFS to find all shortest paths
        var visited = std.AutoHashMap(u64, u32).init(self.allocator);
        defer visited.deinit();

        var parents = std.AutoHashMap(u64, std.ArrayList(PathInfo)).init(self.allocator);
        defer {
            var it = parents.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit();
            }
            parents.deinit();
        }

        const PathInfo = struct {
            node: u64,
            edge: ?u64,
        };

        var queue = std.ArrayList(QueueItem){};
        defer queue.deinit();

        const QueueItem = struct {
            node: u64,
            depth: u32,
        };

        try queue.append(.{ .node = start_node, .depth = 0 });
        try visited.put(start_node, 0);

        var shortest_length: ?u32 = null;
        var front: usize = 0;

        while (front < queue.items.len) : (front += 1) {
            const current = queue.items[front];

            // If we've found a path and current depth exceeds it, stop
            if (shortest_length) |len| {
                if (current.depth > len) break;
            }

            if (current.node == end_node) {
                shortest_length = current.depth;
                continue; // Keep searching for other paths of same length
            }

            if (max_depth) |max| {
                if (current.depth >= max) continue;
            }

            const neighbors = try self.getNeighbors(current.node, relationship_types, direction);
            defer self.allocator.free(neighbors);

            for (neighbors) |neighbor| {
                const neighbor_depth = visited.get(neighbor.node);

                if (neighbor_depth == null or neighbor_depth.? == current.depth + 1) {
                    // First visit or another shortest path to this node
                    if (neighbor_depth == null) {
                        try visited.put(neighbor.node, current.depth + 1);
                        try queue.append(.{
                            .node = neighbor.node,
                            .depth = current.depth + 1,
                        });
                    }

                    // Add parent
                    const result = try parents.getOrPut(neighbor.node);
                    if (!result.found_existing) {
                        result.value_ptr.* = std.ArrayList(PathInfo){};
                    }
                    try result.value_ptr.append(.{
                        .node = current.node,
                        .edge = neighbor.edge,
                    });
                }
            }
        }

        // Reconstruct all paths
        if (shortest_length != null) {
            try self.reconstructAllPaths(start_node, end_node, &parents, &paths);
        }

        return paths.toOwnedSlice();
    }

    // degrees() - calculates degree centrality
    pub fn degrees(
        self: *BuiltinAlgorithms,
        nodes: ?[]u64,
        direction: graph_exec.Direction,
    ) ![]CentralityResult {
        const target_nodes = nodes orelse try self.graph.getAllNodes();
        defer if (nodes == null) self.allocator.free(target_nodes);

        var results = std.ArrayList(CentralityResult){};

        for (target_nodes) |node| {
            const degree = switch (direction) {
                .outgoing => try self.graph.getOutDegree(node),
                .incoming => try self.graph.getInDegree(node),
                .both => blk: {
                    const out = try self.graph.getOutDegree(node);
                    const in = try self.graph.getInDegree(node);
                    break :blk out + in;
                },
            };

            try results.append(.{
                .node_id = node,
                .score = @as(f64, @floatFromInt(degree)),
            });
        }

        return results.toOwnedSlice();
    }

    // closeness() - calculates closeness centrality
    pub fn closeness(
        self: *BuiltinAlgorithms,
        nodes: ?[]u64,
        normalized: bool,
    ) ![]CentralityResult {
        const target_nodes = nodes orelse try self.graph.getAllNodes();
        defer if (nodes == null) self.allocator.free(target_nodes);

        var results = std.ArrayList(CentralityResult){};

        for (target_nodes) |node| {
            var total_distance: f64 = 0;
            var reachable_count: u64 = 0;

            // BFS from this node to all others
            var distances = try self.computeDistances(node);
            defer distances.deinit();

            var it = distances.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.* != node) {
                    total_distance += @as(f64, @floatFromInt(entry.value_ptr.*));
                    reachable_count += 1;
                }
            }

            const closeness_score = if (reachable_count > 0) blk: {
                const raw_closeness = @as(f64, @floatFromInt(reachable_count)) / total_distance;
                if (normalized) {
                    const n = @as(f64, @floatFromInt(target_nodes.len - 1));
                    break :blk raw_closeness * n;
                } else {
                    break :blk raw_closeness;
                }
            } else 0.0;

            try results.append(.{
                .node_id = node,
                .score = closeness_score,
            });
        }

        return results.toOwnedSlice();
    }

    // eigenvector() - calculates eigenvector centrality
    pub fn eigenvector(
        self: *BuiltinAlgorithms,
        max_iterations: u32,
        tolerance: f64,
    ) ![]CentralityResult {
        const nodes = try self.graph.getAllNodes();
        defer self.allocator.free(nodes);

        const n = nodes.len;
        if (n == 0) return &[_]CentralityResult{};

        // Initialize eigenvector
        var eigenvector = std.AutoHashMap(u64, f64).init(self.allocator);
        defer eigenvector.deinit();

        for (nodes) |node| {
            try eigenvector.put(node, 1.0 / @sqrt(@as(f64, @floatFromInt(n))));
        }

        var iteration: u32 = 0;
        while (iteration < max_iterations) : (iteration += 1) {
            var new_eigenvector = std.AutoHashMap(u64, f64).init(self.allocator);
            defer new_eigenvector.deinit();

            // Power iteration
            for (nodes) |node| {
                var sum: f64 = 0;

                const neighbors = try self.graph.getIncomingNodes(node);
                defer self.allocator.free(neighbors);

                for (neighbors) |neighbor| {
                    sum += eigenvector.get(neighbor) orelse 0;
                }

                try new_eigenvector.put(node, sum);
            }

            // Normalize
            var norm: f64 = 0;
            var it = new_eigenvector.iterator();
            while (it.next()) |entry| {
                norm += entry.value_ptr.* * entry.value_ptr.*;
            }
            norm = @sqrt(norm);

            if (norm > 0) {
                it = new_eigenvector.iterator();
                while (it.next()) |entry| {
                    entry.value_ptr.* /= norm;
                }
            }

            // Check convergence
            var max_diff: f64 = 0;
            for (nodes) |node| {
                const old_val = eigenvector.get(node) orelse 0;
                const new_val = new_eigenvector.get(node) orelse 0;
                max_diff = @max(max_diff, @abs(new_val - old_val));
            }

            // Update eigenvector
            eigenvector.clearRetainingCapacity();
            it = new_eigenvector.iterator();
            while (it.next()) |entry| {
                try eigenvector.put(entry.key_ptr.*, entry.value_ptr.*);
            }

            if (max_diff < tolerance) break;
        }

        // Convert to results
        var results = std.ArrayList(CentralityResult){};
        var it = eigenvector.iterator();
        while (it.next()) |entry| {
            try results.append(.{
                .node_id = entry.key_ptr.*,
                .score = entry.value_ptr.*,
            });
        }

        return results.toOwnedSlice();
    }

    // louvainCommunities() - Louvain community detection
    pub fn louvainCommunities(
        self: *BuiltinAlgorithms,
        resolution: f64,
    ) ![]Community {
        const nodes = try self.graph.getAllNodes();
        defer self.allocator.free(nodes);

        // Initialize each node in its own community
        var communities = std.AutoHashMap(u64, u64).init(self.allocator);
        defer communities.deinit();

        for (nodes) |node| {
            try communities.put(node, node);
        }

        var improved = true;
        var iteration: u32 = 0;
        const max_iterations: u32 = 100;

        while (improved and iteration < max_iterations) : (iteration += 1) {
            improved = false;

            // Phase 1: Local optimization
            for (nodes) |node| {
                const current_community = communities.get(node).?;
                var best_community = current_community;
                var best_gain: f64 = 0;

                // Get neighbors
                const neighbors = try self.graph.getNeighbors(node);
                defer self.allocator.free(neighbors);

                // Try moving to each neighbor's community
                for (neighbors) |neighbor| {
                    const neighbor_community = communities.get(neighbor) orelse continue;
                    if (neighbor_community == current_community) continue;

                    // Calculate modularity gain
                    const gain = try self.calculateModularityGain(
                        &communities,
                        node,
                        current_community,
                        neighbor_community,
                        resolution,
                    );

                    if (gain > best_gain) {
                        best_gain = gain;
                        best_community = neighbor_community;
                    }
                }

                if (best_community != current_community) {
                    try communities.put(node, best_community);
                    improved = true;
                }
            }
        }

        // Group nodes by community
        var community_nodes = std.AutoHashMap(u64, std.ArrayList(u64)).init(self.allocator);
        defer {
            var it = community_nodes.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit();
            }
            community_nodes.deinit();
        }

        var it = communities.iterator();
        while (it.next()) |entry| {
            const result = try community_nodes.getOrPut(entry.value_ptr.*);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(u64){};
            }
            try result.value_ptr.append(entry.key_ptr.*);
        }

        // Calculate modularity for each community
        const total_edges = try self.graph.getEdgeCount();
        const m = @as(f64, @floatFromInt(total_edges));

        // Convert to Community structs
        var results = std.ArrayList(Community){};
        var comm_it = community_nodes.iterator();
        var comm_id: u64 = 0;

        while (comm_it.next()) |entry| : (comm_id += 1) {
            const community_node_list = entry.value_ptr.*;

            // Calculate modularity for this community
            var internal_edges: u64 = 0;
            var total_degree: u64 = 0;

            for (community_node_list.items) |node| {
                const neighbors = try self.graph.getNeighbors(node);
                defer self.allocator.free(neighbors);

                total_degree += neighbors.len;

                for (neighbors) |neighbor| {
                    const neighbor_comm = communities.get(neighbor) orelse continue;
                    if (neighbor_comm == entry.key_ptr.*) {
                        internal_edges += 1;
                    }
                }
            }

            const modularity = if (m > 0) blk: {
                const internal = @as(f64, @floatFromInt(internal_edges)) / (2.0 * m);
                const expected = std.math.pow(f64, @as(f64, @floatFromInt(total_degree)) / (2.0 * m), 2);
                break :blk internal - expected;
            } else 0.0;

            try results.append(.{
                .id = comm_id,
                .nodes = try community_node_list.toOwnedSlice(),
                .modularity = modularity,
            });
        }

        return results.toOwnedSlice();
    }

    // Helper types
    pub const CentralityResult = struct {
        node_id: u64,
        score: f64,
    };

    pub const Community = struct {
        id: u64,
        nodes: []u64,
        modularity: f64,
    };

    const Neighbor = struct {
        node: u64,
        edge: ?u64,
    };

    // Helper functions
    fn getNeighbors(
        self: *BuiltinAlgorithms,
        node: u64,
        relationship_types: ?[]const []const u8,
        direction: graph_exec.Direction,
    ) ![]Neighbor {
        _ = relationship_types; // TODO: Filter by relationship type

        var neighbors = std.ArrayList(Neighbor){};

        switch (direction) {
            .outgoing => {
                const out_nodes = try self.graph.getOutgoingNodes(node);
                defer self.allocator.free(out_nodes);
                for (out_nodes) |n| {
                    try neighbors.append(.{ .node = n, .edge = null });
                }
            },
            .incoming => {
                const in_nodes = try self.graph.getIncomingNodes(node);
                defer self.allocator.free(in_nodes);
                for (in_nodes) |n| {
                    try neighbors.append(.{ .node = n, .edge = null });
                }
            },
            .both => {
                const out_nodes = try self.graph.getOutgoingNodes(node);
                defer self.allocator.free(out_nodes);
                const in_nodes = try self.graph.getIncomingNodes(node);
                defer self.allocator.free(in_nodes);

                for (out_nodes) |n| {
                    try neighbors.append(.{ .node = n, .edge = null });
                }
                for (in_nodes) |n| {
                    try neighbors.append(.{ .node = n, .edge = null });
                }
            },
        }

        return neighbors.toOwnedSlice();
    }

    fn reconstructPath(
        self: *BuiltinAlgorithms,
        start: u64,
        end: u64,
        parent: *std.AutoHashMap(u64, PathInfo),
    ) !graph_exec.Path {
        var nodes = std.ArrayList(u64){};
        var edges = std.ArrayList(u64){};

        var current = end;
        try nodes.append(current);

        while (current != start) {
            if (parent.get(current)) |info| {
                current = info.node;
                try nodes.append(current);
                if (info.edge) |edge| {
                    try edges.append(edge);
                }
            } else {
                break;
            }
        }

        // Reverse to get path from start to end
        std.mem.reverse(u64, nodes.items);
        std.mem.reverse(u64, edges.items);

        return .{
            .nodes = try nodes.toOwnedSlice(),
            .edges = try edges.toOwnedSlice(),
            .length = nodes.items.len - 1,
        };
    }

    fn reconstructAllPaths(
        self: *BuiltinAlgorithms,
        start: u64,
        end: u64,
        parents: *std.AutoHashMap(u64, std.ArrayList(PathInfo)),
        paths: *std.ArrayList(graph_exec.Path),
    ) !void {
        // Recursive path reconstruction for multiple parents
        var current_path = std.ArrayList(u64){};
        defer current_path.deinit();

        try self.reconstructAllPathsRecursive(start, end, parents, &current_path, paths);
    }

    fn reconstructAllPathsRecursive(
        self: *BuiltinAlgorithms,
        start: u64,
        current: u64,
        parents: *std.AutoHashMap(u64, std.ArrayList(PathInfo)),
        current_path: *std.ArrayList(u64),
        paths: *std.ArrayList(graph_exec.Path),
    ) !void {
        try current_path.append(current);
        defer _ = current_path.pop();

        if (current == start) {
            // Found complete path
            var path_nodes = try self.allocator.alloc(u64, current_path.items.len);
            std.mem.copy(u64, path_nodes, current_path.items);
            std.mem.reverse(u64, path_nodes);

            try paths.append(.{
                .nodes = path_nodes,
                .edges = &[_]u64{}, // TODO: Track edges
                .length = path_nodes.len - 1,
            });
            return;
        }

        if (parents.get(current)) |parent_list| {
            for (parent_list.items) |parent_info| {
                try self.reconstructAllPathsRecursive(
                    start,
                    parent_info.node,
                    parents,
                    current_path,
                    paths,
                );
            }
        }
    }

    fn computeDistances(self: *BuiltinAlgorithms, start: u64) !std.AutoHashMap(u64, u32) {
        var distances = std.AutoHashMap(u64, u32).init(self.allocator);
        var queue = std.ArrayList(struct { node: u64, dist: u32 }){};
        defer queue.deinit();

        try distances.put(start, 0);
        try queue.append(.{ .node = start, .dist = 0 });

        var front: usize = 0;
        while (front < queue.items.len) : (front += 1) {
            const current = queue.items[front];

            const neighbors = try self.graph.getNeighbors(current.node);
            defer self.allocator.free(neighbors);

            for (neighbors) |neighbor| {
                if (!distances.contains(neighbor)) {
                    try distances.put(neighbor, current.dist + 1);
                    try queue.append(.{ .node = neighbor, .dist = current.dist + 1 });
                }
            }
        }

        return distances;
    }

    fn calculateModularityGain(
        self: *BuiltinAlgorithms,
        communities: *std.AutoHashMap(u64, u64),
        node: u64,
        from_community: u64,
        to_community: u64,
        resolution: f64,
    ) !f64 {
        _ = from_community;

        const total_edges = try self.graph.getEdgeCount();
        if (total_edges == 0) return 0;

        const m = @as(f64, @floatFromInt(total_edges));
        const node_degree = @as(f64, @floatFromInt((try self.graph.getNeighbors(node)).len));

        // Calculate sum of edges from node to nodes in to_community
        var edges_to_community: f64 = 0;
        const neighbors = try self.graph.getNeighbors(node);
        defer self.allocator.free(neighbors);

        for (neighbors) |neighbor| {
            if (communities.get(neighbor)) |comm| {
                if (comm == to_community) {
                    edges_to_community += 1;
                }
            }
        }

        // Calculate total degree of nodes in to_community
        var community_degree: f64 = 0;
        var it = communities.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == to_community) {
                const degree = (try self.graph.getNeighbors(entry.key_ptr.*)).len;
                self.allocator.free(degree);
                community_degree += @as(f64, @floatFromInt(degree));
            }
        }

        // Modularity gain formula
        const gain = (edges_to_community / m) -
            resolution * (node_degree * community_degree) / (2.0 * m * m);

        return gain;
    }
};
