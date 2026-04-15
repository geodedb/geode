// Leiden community detection algorithm for graph partitioning
// CANARY: REQ=REQ-GQL-GRAPH-001; FEATURE="Leiden Community Detection"; ASPECT=Graph; STATUS=TESTED; TEST=TestCANARY_Leiden; OWNER=graph; UPDATED=2025-09-29

const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
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

    /// Neighbor entry in the adjacency index.
    const Neighbor = struct {
        id: u64,
        weight: f64,
    };

    /// Pre-built adjacency index: node_id -> list of (neighbor_id, weight) pairs.
    /// Built once from the edge list, then used by all inner functions to avoid
    /// O(E) scans when only O(degree) work is needed.
    const AdjacencyIndex = std.AutoHashMap(u64, std.ArrayList(Neighbor));

    fn buildAdjacency(allocator: Allocator, graph: Graph) !AdjacencyIndex {
        var adj = AdjacencyIndex.init(allocator);
        errdefer {
            var it = adj.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit();
            adj.deinit();
        }
        // Ensure capacity for every node so getOrPut never fails on resize mid-loop.
        try adj.ensureTotalCapacity(@intCast(graph.nodes.len));
        for (graph.nodes) |node| {
            try adj.put(node, std.ArrayList(Neighbor).init(allocator));
        }
        for (graph.edges) |edge| {
            if (adj.getPtr(edge.source)) |list| {
                try list.append(.{ .id = edge.target, .weight = edge.weight });
            }
            if (edge.source != edge.target) {
                if (adj.getPtr(edge.target)) |list| {
                    try list.append(.{ .id = edge.source, .weight = edge.weight });
                }
            }
        }
        return adj;
    }

    fn deinitAdjacency(adj: *AdjacencyIndex) void {
        var it = adj.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit();
        adj.deinit();
    }

    pub fn init(allocator: Allocator, resolution: f64) LeidenDetector {
        var prng = std.rand.DefaultPrng.init(@intCast(compat_milliTimestamp()));
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
        // Build adjacency index once -- O(V+E) -- then used by all inner functions
        var adj = try buildAdjacency(self.allocator, graph);
        defer deinitAdjacency(&adj);

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

        // Calculate node degrees from adjacency index -- O(V+E)
        for (graph.nodes) |node| {
            const neighbors = adj.get(node) orelse continue;
            var degree: f64 = 0;
            var self_loops: f64 = 0;
            for (neighbors.items) |nb| {
                degree += nb.weight;
                if (nb.id == node) {
                    self_loops += nb.weight;
                }
            }
            if (node_info.getPtr(node)) |info| {
                info.degree = degree;
                info.self_loops = self_loops;
            }
        }

        // Main optimization loop
        var iterations: u32 = 0;
        var prev_modularity: f64 = try self.calculateModularity(&node_info, graph);

        while (iterations < self.max_iterations) {
            iterations += 1;

            // Phase 1: Local node movements (fast local search)
            const moved = try self.localMoveNodes(&node_info, &communities, graph, &adj);
            if (!moved) break;

            // Phase 2: Network aggregation
            try self.aggregateNetwork(&node_info, &communities, graph);

            // Phase 3: Refinement (unique to Leiden)
            try self.refinePartition(&node_info, &communities, graph, &adj);

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
        adj: *const AdjacencyIndex,
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

            // Get neighboring communities using adjacency index -- O(degree)
            var neighbor_comms = std.AutoHashMap(u64, f64).init(self.allocator);
            defer neighbor_comms.deinit();

            if (adj.get(node)) |neighbors| {
                for (neighbors.items) |nb| {
                    const nb_info = node_info.get(nb.id) orelse continue;
                    const weight = neighbor_comms.get(nb_info.community) orelse 0;
                    try neighbor_comms.put(nb_info.community, weight + nb.weight);
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

    // CANARY: REQ=REQ-GRAPH-LEIDEN-AGG-001; FEATURE="Leiden Network Aggregation"; ASPECT=Aggregation; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=graph; UPDATED=2026-01-08
    fn aggregateNetwork(
        self: *LeidenDetector,
        node_info: *std.AutoHashMap(u64, NodeInfo),
        communities: *std.AutoHashMap(u64, *Community),
        graph: Graph,
    ) !void {
        // Network aggregation creates super-nodes from communities
        // Each community becomes a single node in the aggregated graph

        // Calculate inter-community and intra-community weights
        var inter_weights = std.AutoHashMap(struct { u64, u64 }, f64).init(self.allocator);
        defer inter_weights.deinit();

        for (graph.edges) |edge| {
            const source_info = node_info.get(edge.source) orelse continue;
            const target_info = node_info.get(edge.target) orelse continue;

            const source_comm = source_info.community;
            const target_comm = target_info.community;

            // Update community weights
            if (communities.getPtr(source_comm)) |comm_ptr| {
                comm_ptr.*.total_weight += edge.weight;
                if (source_comm == target_comm) {
                    comm_ptr.*.internal_weight += edge.weight;
                }
            }

            // Track inter-community edge weights
            if (source_comm != target_comm) {
                const key = if (source_comm < target_comm)
                    .{ source_comm, target_comm }
                else
                    .{ target_comm, source_comm };

                const current = inter_weights.get(key) orelse 0;
                try inter_weights.put(key, current + edge.weight);
            }
        }

        // Merge communities that are strongly connected
        const merge_threshold: f64 = 0.1; // Communities with > 10% of edges going to another should merge
        var it = inter_weights.iterator();
        while (it.next()) |entry| {
            const comm1_id = entry.key_ptr[0];
            const comm2_id = entry.key_ptr[1];
            const weight = entry.value_ptr.*;

            const comm1 = communities.get(comm1_id) orelse continue;
            const comm2 = communities.get(comm2_id) orelse continue;

            // Calculate merge potential
            const total = comm1.total_weight + comm2.total_weight;
            if (total > 0 and weight / total > merge_threshold) {
                // Consider merging - check modularity gain
                const gain = self.calculateModularityGain(
                    comm1.total_weight,
                    weight,
                    comm2,
                    graph,
                );

                if (gain > self.min_modularity_gain) {
                    // Merge comm2 into comm1
                    try self.mergeCommunities(comm1_id, comm2_id, node_info, communities);
                }
            }
        }
    }

    fn mergeCommunities(
        self: *LeidenDetector,
        target_comm_id: u64,
        source_comm_id: u64,
        node_info: *std.AutoHashMap(u64, NodeInfo),
        communities: *std.AutoHashMap(u64, *Community),
    ) !void {
        const source_comm = communities.get(source_comm_id) orelse return;
        const target_comm = communities.getPtr(target_comm_id) orelse return;

        // Move all nodes from source to target
        for (source_comm.nodes.items) |node| {
            try target_comm.*.nodes.append(node);
            if (node_info.getPtr(node)) |info| {
                info.community = target_comm_id;
            }
        }

        // Update weights
        target_comm.*.internal_weight += source_comm.internal_weight;
        target_comm.*.total_weight += source_comm.total_weight;

        // Remove source community
        source_comm.nodes.deinit();
        self.allocator.destroy(source_comm);
        _ = communities.remove(source_comm_id);
    }

    fn refinePartition(
        self: *LeidenDetector,
        node_info: *std.AutoHashMap(u64, NodeInfo),
        communities: *std.AutoHashMap(u64, *Community),
        graph: Graph,
        adj: *const AdjacencyIndex,
    ) !void {
        // Refinement phase unique to Leiden algorithm
        // Ensures communities are well-connected subgraphs

        var comm_it = communities.iterator();
        while (comm_it.next()) |entry| {
            const comm = entry.value_ptr.*;
            if (comm.nodes.items.len <= 1) continue;

            // Check if community is well-connected
            const is_connected = try self.isWellConnected(comm, node_info, adj);
            if (!is_connected) {
                // Split disconnected community
                try self.splitCommunity(comm, node_info, communities, graph, adj);
            }
        }
    }

    fn isWellConnected(
        self: *LeidenDetector,
        community: *Community,
        node_info: *std.AutoHashMap(u64, NodeInfo),
        adj: *const AdjacencyIndex,
    ) !bool {
        _ = node_info;

        if (community.nodes.items.len <= 1) return true;

        // Build a set of community members for O(1) membership tests
        var comm_set = std.AutoHashMap(u64, void).init(self.allocator);
        defer comm_set.deinit();
        for (community.nodes.items) |node| {
            try comm_set.put(node, {});
        }

        // Simple connectivity check using BFS with adjacency index
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

            // Find neighbors in same community using adjacency index -- O(degree)
            const neighbors = adj.get(current) orelse continue;
            for (neighbors.items) |nb| {
                if (comm_set.contains(nb.id) and !visited.contains(nb.id)) {
                    try visited.put(nb.id, {});
                    try queue.append(nb.id);
                }
            }
        }

        return visited.count() == community.nodes.items.len;
    }

    // CANARY: REQ=REQ-GRAPH-LEIDEN-SPLIT-001; FEATURE="Leiden Split Community"; ASPECT=Graph; STATUS=TESTED; TEST=TestCANARY_Leiden; OWNER=graph; UPDATED=2025-10-16
    fn splitCommunity(
        self: *LeidenDetector,
        community: *Community,
        node_info: *std.AutoHashMap(u64, NodeInfo),
        communities: *std.AutoHashMap(u64, *Community),
        graph: Graph,
        adj: *const AdjacencyIndex,
    ) !void {
        _ = graph;

        // Build set of community members for O(1) membership tests
        var community_nodes = std.AutoHashMap(u64, void).init(self.allocator);
        defer community_nodes.deinit();
        for (community.nodes.items) |node| {
            try community_nodes.put(node, {});
        }

        // Find connected components using BFS with adjacency index
        var visited = std.AutoHashMap(u64, void).init(self.allocator);
        defer visited.deinit();

        var components = std.ArrayList(std.ArrayList(u64)).init(self.allocator);
        defer {
            for (components.items) |*comp| {
                comp.deinit();
            }
            components.deinit();
        }

        // Find all connected components
        for (community.nodes.items) |start_node| {
            if (visited.contains(start_node)) continue;

            // BFS to find all nodes in this component
            var component = std.ArrayList(u64).init(self.allocator);
            var queue = std.ArrayList(u64).init(self.allocator);
            defer queue.deinit();

            try queue.append(start_node);
            try visited.put(start_node, {});

            while (queue.items.len > 0) {
                const current = queue.orderedRemove(0);
                try component.append(current);

                // Find neighbors within community using adjacency index -- O(degree)
                const neighbors = adj.get(current) orelse continue;
                for (neighbors.items) |nb| {
                    if (community_nodes.contains(nb.id) and !visited.contains(nb.id)) {
                        try visited.put(nb.id, {});
                        try queue.append(nb.id);
                    }
                }
            }

            try components.append(component);
        }

        // If only one component, community is already connected
        if (components.items.len <= 1) return;

        // First component stays in original community
        community.nodes.clearRetainingCapacity();
        for (components.items[0].items) |node| {
            try community.nodes.append(node);
        }

        // Create new communities for remaining components
        for (components.items[1..]) |component| {
            // Generate new community ID from first node in component
            const new_id = component.items[0];

            // Build component member set for O(1) lookups
            var comp_set = std.AutoHashMap(u64, void).init(self.allocator);
            defer comp_set.deinit();
            for (component.items) |node| {
                try comp_set.put(node, {});
            }

            var new_comm = try self.allocator.create(Community);
            new_comm.* = .{
                .id = new_id,
                .nodes = std.ArrayList(u64).init(self.allocator),
                .internal_weight = 0,
                .total_weight = 0,
            };

            // Move nodes to new community and calculate weights from adjacency
            for (component.items) |node| {
                try new_comm.nodes.append(node);

                // Update node_info to point to new community
                if (node_info.getPtr(node)) |info| {
                    info.community = new_id;
                }

                // Accumulate weights from this node's edges
                const neighbors = adj.get(node) orelse continue;
                for (neighbors.items) |nb| {
                    new_comm.total_weight += nb.weight;
                    if (comp_set.contains(nb.id)) {
                        new_comm.internal_weight += nb.weight;
                    }
                }
            }

            try communities.put(new_id, new_comm);
        }

        // Recalculate weights for original community using adjacency index
        // Build member set for the (now reduced) original community
        var orig_set = std.AutoHashMap(u64, void).init(self.allocator);
        defer orig_set.deinit();
        for (community.nodes.items) |node| {
            try orig_set.put(node, {});
        }

        community.internal_weight = 0;
        community.total_weight = 0;
        for (community.nodes.items) |node| {
            const neighbors = adj.get(node) orelse continue;
            for (neighbors.items) |nb| {
                community.total_weight += nb.weight;
                if (orig_set.contains(nb.id)) {
                    community.internal_weight += nb.weight;
                }
            }
        }
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
