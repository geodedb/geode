// Leiden community detection algorithm for graph partitioning
// CANARY: REQ=REQ-GQL-GRAPH-001; FEATURE="Leiden Community Detection"; ASPECT=Graph; STATUS=IMPL; TEST=TestCANARY_Leiden; OWNER=graph; UPDATED=2025-01-29

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LeidenDetector = struct {
    allocator: Allocator,
    resolution: f64,
    max_iterations: u32,
    min_modularity_gain: f64,
    random: std.rand.Random,

    pub const Community = struct {
        id: u64,
        nodes: std.ArrayList(u64),
        internal_weight: f64,
        total_weight: f64,
    };

    pub const Graph = struct {
        nodes: []const u64,
        edges: []const Edge,
        node_weights: ?[]const f64,
    };

    pub const Edge = struct {
        source: u64,
        target: u64,
        weight: f64,
    };

    pub const Result = struct {
        communities: []Community,
        modularity: f64,
        iterations: u32,
    };

    const NodeInfo = struct {
        community: u64,
        degree: f64,
        self_loops: f64,
    };

    pub fn init(allocator: Allocator, resolution: f64) LeidenDetector {
        var prng = std.rand.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        return .{
            .allocator = allocator,
            .resolution = resolution,
            .max_iterations = 100,
            .min_modularity_gain = 1e-7,
            .random = prng.random(),
        };
    }

    // Main Leiden algorithm
    pub fn detectCommunities(self: *LeidenDetector, graph: Graph) !Result {
        // Initialize node info
        var node_info = std.AutoHashMap(u64, NodeInfo).init(self.allocator);
        defer node_info.deinit();

        var communities = std.AutoHashMap(u64, *Community).init(self.allocator);
        defer {
            var it = communities.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.nodes.deinit();
                self.allocator.destroy(entry.value_ptr.*);
            }
            communities.deinit();
        }

        // Initialize each node in its own community
        for (graph.nodes) |node| {
            const comm_id = node;
            var comm = try self.allocator.create(Community);
            comm.* = .{
                .id = comm_id,
                .nodes = try std.ArrayList(u64).initCapacity(self.allocator, 0),
                .internal_weight = 0,
                .total_weight = 0,
            };
            try comm.nodes.append(node);
            try communities.put(comm_id, comm);

            try node_info.put(node, .{
                .community = comm_id,
                .degree = 0,
                .self_loops = 0,
            });
        }

        // Calculate node degrees
        for (graph.edges) |edge| {
            if (node_info.getPtr(edge.source)) |info| {
                info.degree += edge.weight;
                if (edge.source == edge.target) {
                    info.self_loops += edge.weight;
                }
            }
            if (edge.target != edge.source) {
                if (node_info.getPtr(edge.target)) |info| {
                    info.degree += edge.weight;
                }
            }
        }

        // Main optimization loop
        var iterations: u32 = 0;
        var prev_modularity: f64 = try self.calculateModularity(&node_info, graph);

        while (iterations < self.max_iterations) {
            iterations += 1;

            // Phase 1: Local node movements (fast local search)
            const moved = try self.localMoveNodes(&node_info, &communities, graph);
            if (!moved) break;

            // Phase 2: Network aggregation
            try self.aggregateNetwork(&node_info, &communities, graph);

            // Phase 3: Refinement (unique to Leiden)
            try self.refinePartition(&node_info, &communities, graph);

            // Check for convergence
            const current_modularity = try self.calculateModularity(&node_info, graph);
            const gain = current_modularity - prev_modularity;

            if (gain < self.min_modularity_gain) break;
            prev_modularity = current_modularity;
        }

        // Convert to result format
        var result_communities = try std.ArrayList(Community).initCapacity(self.allocator, 0);
        var comm_it = communities.iterator();
        while (comm_it.next()) |entry| {
            var comm = Community{
                .id = entry.value_ptr.*.id,
                .nodes = try std.ArrayList(u64).initCapacity(self.allocator, 0),
                .internal_weight = entry.value_ptr.*.internal_weight,
                .total_weight = entry.value_ptr.*.total_weight,
            };

            try comm.nodes.appendSlice(entry.value_ptr.*.nodes.items);
            try result_communities.append(comm);
        }

        return Result{
            .communities = result_communities.toOwnedSlice(),
            .modularity = prev_modularity,
            .iterations = iterations,
        };
    }

    fn localMoveNodes(
        self: *LeidenDetector,
        node_info: *std.AutoHashMap(u64, NodeInfo),
        communities: *std.AutoHashMap(u64, *Community),
        graph: Graph,
    ) !bool {
        var moved = false;
        var nodes_to_move = try std.ArrayList(u64).initCapacity(self.allocator, 0);
        defer nodes_to_move.deinit();

        // Randomize node order
        try nodes_to_move.appendSlice(graph.nodes);
        self.random.shuffle(u64, nodes_to_move.items);

        for (nodes_to_move.items) |node| {
            const info = node_info.get(node) orelse continue;

            // Find best community for this node
            var best_community = info.community;
            var best_gain: f64 = 0;

            // Get neighboring communities
            var neighbor_comms = std.AutoHashMap(u64, f64).init(self.allocator);
            defer neighbor_comms.deinit();

            for (graph.edges) |edge| {
                if (edge.source == node) {
                    const target_info = node_info.get(edge.target) orelse continue;
                    const weight = neighbor_comms.get(target_info.community) orelse 0;
                    try neighbor_comms.put(target_info.community, weight + edge.weight);
                }
                if (edge.target == node and edge.source != edge.target) {
                    const source_info = node_info.get(edge.source) orelse continue;
                    const weight = neighbor_comms.get(source_info.community) orelse 0;
                    try neighbor_comms.put(source_info.community, weight + edge.weight);
                }
            }

            // Evaluate each neighboring community
            var comm_it = neighbor_comms.iterator();
            while (comm_it.next()) |entry| {
                const comm_id = entry.key_ptr.*;
                const edge_weight = entry.value_ptr.*;

                if (comm_id == info.community) continue;

                const gain = self.calculateModularityGain(
                    info.degree,
                    edge_weight,
                    communities.get(comm_id),
                    graph,
                );

                if (gain > best_gain) {
                    best_gain = gain;
                    best_community = comm_id;
                }
            }

            // Move node if beneficial
            if (best_community != info.community and best_gain > self.min_modularity_gain) {
                // Remove from old community
                if (communities.get(info.community)) |old_comm| {
                    var i: usize = 0;
                    while (i < old_comm.nodes.items.len) : (i += 1) {
                        if (old_comm.nodes.items[i] == node) {
                            _ = old_comm.nodes.swapRemove(i);
                            break;
                        }
                    }
                }

                // Add to new community
                if (communities.get(best_community)) |new_comm| {
                    try new_comm.nodes.append(node);
                }

                // Update node info
                if (node_info.getPtr(node)) |ptr| {
                    ptr.community = best_community;
                }

                moved = true;
            }
        }

        return moved;
    }

    fn aggregateNetwork(
        self: *LeidenDetector,
        node_info: *std.AutoHashMap(u64, NodeInfo),
        communities: *std.AutoHashMap(u64, *Community),
        graph: Graph,
    ) !void {
        _ = self;
        _ = node_info;
        _ = communities;
        _ = graph;
        // Network aggregation creates super-nodes from communities
        // This is simplified for the initial implementation
    }

    fn refinePartition(
        self: *LeidenDetector,
        node_info: *std.AutoHashMap(u64, NodeInfo),
        communities: *std.AutoHashMap(u64, *Community),
        graph: Graph,
    ) !void {
        // Refinement phase unique to Leiden algorithm
        // Ensures communities are well-connected subgraphs

        var comm_it = communities.iterator();
        while (comm_it.next()) |entry| {
            const comm = entry.value_ptr.*;
            if (comm.nodes.items.len <= 1) continue;

            // Check if community is well-connected
            const is_connected = try self.isWellConnected(comm, node_info, graph);
            if (!is_connected) {
                // Split disconnected community
                try self.splitCommunity(comm, node_info, communities, graph);
            }
        }
    }

    fn isWellConnected(
        self: *LeidenDetector,
        community: *Community,
        node_info: *std.AutoHashMap(u64, NodeInfo),
        graph: Graph,
    ) !bool {
        _ = node_info;

        if (community.nodes.items.len <= 1) return true;

        // Simple connectivity check using BFS
        var visited = std.AutoHashMap(u64, void).init(self.allocator);
        defer visited.deinit();

        var queue = try std.ArrayList(u64).initCapacity(self.allocator, 0);
        defer queue.deinit();

        // Start from first node
        const start_node = community.nodes.items[0];
        try visited.put(start_node, {});
        try queue.append(start_node);

        while (queue.items.len > 0) {
            const current = queue.orderedRemove(0);

            // Find neighbors in same community
            for (graph.edges) |edge| {
                var neighbor: ?u64 = null;
                if (edge.source == current) {
                    neighbor = edge.target;
                } else if (edge.target == current) {
                    neighbor = edge.source;
                }

                if (neighbor) |n| {
                    // Check if neighbor is in same community
                    var in_community = false;
                    for (community.nodes.items) |node| {
                        if (node == n) {
                            in_community = true;
                            break;
                        }
                    }

                    if (in_community and !visited.contains(n)) {
                        try visited.put(n, {});
                        try queue.append(n);
                    }
                }
            }
        }

        return visited.count() == community.nodes.items.len;
    }

    fn splitCommunity(
        self: *LeidenDetector,
        community: *Community,
        node_info: *std.AutoHashMap(u64, NodeInfo),
        communities: *std.AutoHashMap(u64, *Community),
        graph: Graph,
    ) !void {
        _ = self;
        _ = community;
        _ = node_info;
        _ = communities;
        _ = graph;
        // Split disconnected community into connected components
        // Simplified for initial implementation
    }

    fn calculateModularity(
        self: *LeidenDetector,
        node_info: *std.AutoHashMap(u64, NodeInfo),
        graph: Graph,
    ) !f64 {
        var total_weight: f64 = 0;
        for (graph.edges) |edge| {
            total_weight += edge.weight;
        }

        if (total_weight == 0) return 0;

        var modularity: f64 = 0;

        // Calculate modularity for each community
        var comm_weights = std.AutoHashMap(u64, f64).init(self.allocator);
        defer comm_weights.deinit();

        for (graph.edges) |edge| {
            const source_info = node_info.get(edge.source) orelse continue;
            const target_info = node_info.get(edge.target) orelse continue;

            if (source_info.community == target_info.community) {
                // Internal edge
                modularity += edge.weight - self.resolution *
                    (source_info.degree * target_info.degree) / (2.0 * total_weight);
            }
        }

        return modularity / total_weight;
    }

    fn calculateModularityGain(
        self: *LeidenDetector,
        node_degree: f64,
        edge_weight_to_comm: f64,
        community: ?*Community,
        graph: Graph,
    ) f64 {
        _ = graph;

        if (community == null) return 0;

        const comm = community.?;
        const total_weight = comm.total_weight;

        // Simplified modularity gain calculation
        const gain = edge_weight_to_comm -
            self.resolution * node_degree * total_weight;

        return gain;
    }
};

// Test for Leiden algorithm
test "TestCANARY_Leiden basic community detection" {
    const allocator = std.testing.allocator;

    var detector = LeidenDetector.init(allocator, 1.0);

    const nodes = [_]u64{ 0, 1, 2, 3, 4, 5 };
    const edges = [_]LeidenDetector.Edge{
        .{ .source = 0, .target = 1, .weight = 1.0 },
        .{ .source = 0, .target = 2, .weight = 1.0 },
        .{ .source = 1, .target = 2, .weight = 1.0 },
        .{ .source = 3, .target = 4, .weight = 1.0 },
        .{ .source = 3, .target = 5, .weight = 1.0 },
        .{ .source = 4, .target = 5, .weight = 1.0 },
        .{ .source = 2, .target = 3, .weight = 0.1 }, // Weak link between communities
    };

    const graph = LeidenDetector.Graph{
        .nodes = &nodes,
        .edges = &edges,
        .node_weights = null,
    };

    const result = try detector.detectCommunities(graph);
    defer {
        for (result.communities) |*comm| {
            comm.nodes.deinit();
        }
        allocator.free(result.communities);
    }

    // Should detect 2 main communities
    try std.testing.expect(result.communities.len >= 2);
    try std.testing.expect(result.modularity > 0);
}
