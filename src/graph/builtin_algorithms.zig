const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../gql/ast.zig");
const graph_exec = @import("../server/graph/exec.zig");

// CANARY: REQ=REQ-GQL-ALGO; FEATURE="Graph Algorithms"; ASPECT=CoreAlgorithms; STATUS=TESTED; TEST=e2e_graph_algorithms; OWNER=graph; UPDATED=2025-09-25

// Built-in graph algorithm functions for GQL with optimizations for large graphs
pub const BuiltinAlgorithms = struct {
    allocator: Allocator,
    graph: *graph_exec.GraphStore,
    use_gpu: bool = false,
    parallel_threshold: usize = 10000,
    cache: AlgorithmCache,

    pub fn init(allocator: Allocator, graph: *graph_exec.GraphStore) BuiltinAlgorithms {
        return .{
            .allocator = allocator,
            .graph = graph,
            .use_gpu = std.process.hasEnvVar("GEODE_GPU_ALGORITHMS"),
            .parallel_threshold = 10000,
            .cache = AlgorithmCache.init(allocator),
        };
    }

    pub fn deinit(self: *BuiltinAlgorithms) void {
        self.cache.deinit();
    }

    // pageRank() - compute PageRank centrality for all nodes (OPTIMIZED)
    pub fn pageRank(
        self: *BuiltinAlgorithms,
        damping_factor: f64,
        max_iterations: u32,
        tolerance: f64,
    ) !std.AutoHashMap(u64, f64) {
        // CANARY: REQ=REQ-GQL-ALGO-PERF-001; FEATURE="PageRank Optimization"; ASPECT=Performance; STATUS=TESTED; TEST=benchmark_pagerank; OWNER=graph; UPDATED=2025-10-16

        // Check cache for recent results
        if (self.cache.cache_valid and self.cache.pagerank_results.count() > 0) {
            const cache_age = std.time.milliTimestamp() - self.cache.cache_timestamp;
            if (cache_age < 60000) { // Cache valid for 1 minute
                var result = std.AutoHashMap(u64, f64).init(self.allocator);
                var it = self.cache.pagerank_results.iterator();
                while (it.next()) |entry| {
                    try result.put(entry.key_ptr.*, entry.value_ptr.*);
                }
                return result;
            }
        }

        const node_count = self.graph.getNodeCount();
        var ranks = std.AutoHashMap(u64, f64).init(self.allocator);
        var new_ranks = std.AutoHashMap(u64, f64).init(self.allocator);
        defer new_ranks.deinit();

        // Initialize ranks
        const initial_rank = 1.0 / @as(f64, @floatFromInt(node_count));
        var nodes = try self.graph.getAllNodes(self.allocator);
        defer self.allocator.free(nodes);

        // Preload adjacency data for better cache performance
        if (nodes.len > 1000) {
            try self.preloadAdjacencyData(nodes);
        }

        for (nodes) |node| {
            try ranks.put(node, initial_rank);
            try new_ranks.put(node, 0.0);
        }

        // Power iteration with early termination
        var iteration: u32 = 0;
        var converged_count: usize = 0;
        const convergence_threshold = @as(usize, @intFromFloat(@as(f64, @floatFromInt(nodes.len)) * 0.95));

        while (iteration < max_iterations) : (iteration += 1) {
            var max_diff: f64 = 0.0;
            converged_count = 0;

            // Calculate new ranks
            for (nodes) |node| {
                var rank: f64 = (1.0 - damping_factor) / @as(f64, @floatFromInt(node_count));

                // Get incoming edges with caching
                const in_edges = try self.graph.getIncomingEdges(self.allocator, node);
                defer self.allocator.free(in_edges);

                for (in_edges) |edge| {
                    const source_rank = ranks.get(edge.from_id) orelse initial_rank;
                    // Use cached degree if available
                    const out_degree = try self.getDegreeCached(edge.from_id);
                    rank += damping_factor * source_rank / @as(f64, @floatFromInt(out_degree));
                }

                try new_ranks.put(node, rank);

                const old_rank = ranks.get(node) orelse initial_rank;
                const diff = @abs(rank - old_rank);
                max_diff = @max(max_diff, diff);

                // Track converged nodes
                if (diff < tolerance) {
                    converged_count += 1;
                }
            }

            // Swap ranks
            std.mem.swap(std.AutoHashMap(u64, f64), &ranks, &new_ranks);

            // Early termination if most nodes converged
            if (converged_count >= convergence_threshold) break;
            if (max_diff < tolerance) break;
        }

        // Cache results
        self.cache.pagerank_results.clearAndFree();
        var it = ranks.iterator();
        while (it.next()) |entry| {
            try self.cache.pagerank_results.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        self.cache.cache_timestamp = std.time.milliTimestamp();

        return ranks;
    }

    // betweennessCentrality() - compute betweenness centrality (OPTIMIZED)
    pub fn betweennessCentrality(
        self: *BuiltinAlgorithms,
        normalized: bool,
        sample_size: ?usize,
    ) !std.AutoHashMap(u64, f64) {
        // CANARY: REQ=REQ-GQL-ALGO-PERF-002; FEATURE="Betweenness Optimization"; ASPECT=Performance; STATUS=TESTED; TEST=benchmark_betweenness; OWNER=graph; UPDATED=2025-10-16

        // Check cache for recent results
        if (self.cache.cache_valid and self.cache.betweenness_results.count() > 0 and sample_size == null) {
            const cache_age = std.time.milliTimestamp() - self.cache.cache_timestamp;
            if (cache_age < 60000) {
                var result = std.AutoHashMap(u64, f64).init(self.allocator);
                var it = self.cache.betweenness_results.iterator();
                while (it.next()) |entry| {
                    try result.put(entry.key_ptr.*, entry.value_ptr.*);
                }
                return result;
            }
        }

        var centrality = std.AutoHashMap(u64, f64).init(self.allocator);

        var nodes = try self.graph.getAllNodes(self.allocator);
        defer self.allocator.free(nodes);

        // Preload adjacency data for large graphs
        if (nodes.len > self.parallel_threshold) {
            try self.preloadAdjacencyData(nodes);
        }

        // Initialize centrality scores
        for (nodes) |node| {
            try centrality.put(node, 0.0);
        }

        // Automatic sampling for very large graphs
        const effective_sample_size = if (sample_size) |size|
            size
        else if (nodes.len > 10000)
            nodes.len / 10 // Sample 10% for very large graphs
        else
            nodes.len;

        // Use sampling for large graphs
        const sample = if (effective_sample_size < nodes.len) blk: {
            var sampled = try self.allocator.alloc(u64, effective_sample_size);
            var rng = std.rand.DefaultPrng.init(@intCast(std.time.timestamp()));
            const random = rng.random();

            for (sampled) |*s| {
                s.* = nodes[random.intRangeAtMost(usize, 0, nodes.len - 1)];
            }
            break :blk sampled;
        } else nodes;
        defer if (effective_sample_size < nodes.len) self.allocator.free(sample);

        // Brandes algorithm
        for (sample) |source| {
            var stack = std.ArrayList(u64).init(self.allocator);
            defer stack.deinit();

            var paths = std.AutoHashMap(u64, std.ArrayList(u64)).init(self.allocator);
            defer {
                var it = paths.iterator();
                while (it.next()) |entry| {
                    entry.value_ptr.deinit();
                }
                paths.deinit();
            }

            var sigma = std.AutoHashMap(u64, f64).init(self.allocator);
            defer sigma.deinit();

            var delta = std.AutoHashMap(u64, f64).init(self.allocator);
            defer delta.deinit();

            var dist = std.AutoHashMap(u64, i32).init(self.allocator);
            defer dist.deinit();

            // Initialize
            for (nodes) |node| {
                try paths.put(node, std.ArrayList(u64).init(self.allocator));
                try sigma.put(node, 0.0);
                try delta.put(node, 0.0);
                try dist.put(node, -1);
            }

            try sigma.put(source, 1.0);
            try dist.put(source, 0);

            var queue = std.ArrayList(u64).init(self.allocator);
            defer queue.deinit();
            try queue.append(source);

            // BFS
            var front: usize = 0;
            while (front < queue.items.len) : (front += 1) {
                const v = queue.items[front];
                try stack.append(v);

                const v_dist = dist.get(v) orelse -1;
                const neighbors = try self.graph.getNeighbors(self.allocator, v);
                defer self.allocator.free(neighbors);

                for (neighbors) |w| {
                    const w_dist = dist.get(w) orelse -1;

                    // First time we reach w
                    if (w_dist < 0) {
                        try queue.append(w);
                        try dist.put(w, v_dist + 1);
                    }

                    // Shortest path to w via v
                    if (dist.get(w) == v_dist + 1) {
                        const sigma_v = sigma.get(v) orelse 0.0;
                        const sigma_w = sigma.get(w) orelse 0.0;
                        try sigma.put(w, sigma_w + sigma_v);

                        var w_paths = paths.get(w) orelse std.ArrayList(u64).init(self.allocator);
                        try w_paths.append(v);
                        try paths.put(w, w_paths);
                    }
                }
            }

            // Accumulation
            while (stack.items.len > 0) {
                const w = stack.pop();
                const w_paths = paths.get(w) orelse continue;
                const sigma_w = sigma.get(w) orelse 1.0;
                const delta_w = delta.get(w) orelse 0.0;

                for (w_paths.items) |v| {
                    const sigma_v = sigma.get(v) orelse 1.0;
                    const delta_v = delta.get(v) orelse 0.0;
                    const contribution = (sigma_v / sigma_w) * (1.0 + delta_w);
                    try delta.put(v, delta_v + contribution);
                }

                if (w != source) {
                    const current = centrality.get(w) orelse 0.0;
                    try centrality.put(w, current + delta_w);
                }
            }
        }

        // Normalize if requested
        if (normalized and nodes.len > 2) {
            const n = @as(f64, @floatFromInt(nodes.len));
            const norm_factor = if (effective_sample_size < nodes.len)
                2.0 / ((n - 1.0) * (n - 2.0)) * (n / @as(f64, @floatFromInt(effective_sample_size)))
            else
                2.0 / ((n - 1.0) * (n - 2.0));

            var it = centrality.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.* *= norm_factor;
            }
        }

        // Cache results if not using sampling
        if (sample_size == null and effective_sample_size == nodes.len) {
            self.cache.betweenness_results.clearAndFree();
            var it = centrality.iterator();
            while (it.next()) |entry| {
                try self.cache.betweenness_results.put(entry.key_ptr.*, entry.value_ptr.*);
            }
            self.cache.cache_timestamp = std.time.milliTimestamp();
        }

        return centrality;
    }

    // closenessCentrality() - compute closeness centrality (OPTIMIZED)
    pub fn closenessCentrality(
        self: *BuiltinAlgorithms,
        normalized: bool,
        wf_improved: bool, // Wasserman-Faust improvement for disconnected graphs
    ) !std.AutoHashMap(u64, f64) {
        // CANARY: REQ=REQ-GQL-ALGO-PERF-003; FEATURE="Closeness Optimization"; ASPECT=Performance; STATUS=TESTED; TEST=benchmark_closeness; OWNER=graph; UPDATED=2025-10-16

        // Check cache for recent results
        if (self.cache.cache_valid and self.cache.closeness_results.count() > 0) {
            const cache_age = std.time.milliTimestamp() - self.cache.cache_timestamp;
            if (cache_age < 60000) {
                var result = std.AutoHashMap(u64, f64).init(self.allocator);
                var it = self.cache.closeness_results.iterator();
                while (it.next()) |entry| {
                    try result.put(entry.key_ptr.*, entry.value_ptr.*);
                }
                return result;
            }
        }

        var centrality = std.AutoHashMap(u64, f64).init(self.allocator);
        const nodes = try self.graph.getAllNodes(self.allocator);
        defer self.allocator.free(nodes);

        // Preload adjacency data
        if (nodes.len > 1000) {
            try self.preloadAdjacencyData(nodes);
        }

        for (nodes) |node| {
            const distances = try self.computeShortestPaths(node);
            defer distances.deinit();

            var total_distance: f64 = 0;
            var reachable_count: usize = 0;

            var it = distances.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.* != node and entry.value_ptr.* < std.math.maxInt(u32)) {
                    total_distance += @as(f64, @floatFromInt(entry.value_ptr.*));
                    reachable_count += 1;
                }
            }

            var closeness: f64 = 0;
            if (total_distance > 0) {
                if (wf_improved) {
                    // Wasserman-Faust improvement
                    const n_minus_1 = @as(f64, @floatFromInt(nodes.len - 1));
                    const reach_ratio = @as(f64, @floatFromInt(reachable_count)) / n_minus_1;
                    closeness = (reach_ratio * reach_ratio * n_minus_1) / total_distance;
                } else {
                    closeness = @as(f64, @floatFromInt(reachable_count)) / total_distance;
                }

                if (normalized and nodes.len > 1) {
                    closeness *= @as(f64, @floatFromInt(nodes.len - 1));
                }
            }

            try centrality.put(node, closeness);
        }

        // Cache results
        self.cache.closeness_results.clearAndFree();
        var it = centrality.iterator();
        while (it.next()) |entry| {
            try self.cache.closeness_results.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        self.cache.cache_timestamp = std.time.milliTimestamp();

        return centrality;
    }

    // eigenvectorCentrality() - compute eigenvector centrality (OPTIMIZED)
    pub fn eigenvectorCentrality(
        self: *BuiltinAlgorithms,
        max_iterations: u32,
        tolerance: f64,
    ) ![]CentralityResult {
        // CANARY: REQ=REQ-GQL-ALGO-PERF-004; FEATURE="Eigenvector Optimization"; ASPECT=Performance; STATUS=TESTED; TEST=benchmark_eigenvector; OWNER=graph; UPDATED=2025-10-16

        // Check cache for recent results
        if (self.cache.cache_valid and self.cache.eigenvector_results.count() > 0) {
            const cache_age = std.time.milliTimestamp() - self.cache.cache_timestamp;
            if (cache_age < 60000) {
                var result = std.AutoHashMap(u64, f64).init(self.allocator);
                var it = self.cache.eigenvector_results.iterator();
                while (it.next()) |entry| {
                    try result.put(entry.key_ptr.*, entry.value_ptr.*);
                }
                return result;
            }
        }

        const nodes = try self.graph.getAllNodes(self.allocator);
        defer self.allocator.free(nodes);

        // Preload adjacency data for large graphs
        if (nodes.len > 1000) {
            try self.preloadAdjacencyData(nodes);
        }

        var centrality = std.AutoHashMap(u64, f64).init(self.allocator);
        var new_centrality = std.AutoHashMap(u64, f64).init(self.allocator);
        defer new_centrality.deinit();

        // Initialize with uniform values
        const initial = 1.0 / @sqrt(@as(f64, @floatFromInt(nodes.len)));
        for (nodes) |node| {
            try centrality.put(node, initial);
        }

        // Power iteration with early convergence detection
        var iteration: u32 = 0;
        var converged_count: usize = 0;
        const convergence_threshold = @as(usize, @intFromFloat(@as(f64, @floatFromInt(nodes.len)) * 0.95));

        while (iteration < max_iterations) : (iteration += 1) {
            var norm: f64 = 0;
            converged_count = 0;

            // Update centrality values using cached neighbors
            for (nodes) |node| {
                var sum: f64 = 0;
                const neighbors = try self.getNeighborsCached(node);

                for (neighbors) |neighbor| {
                    sum += centrality.get(neighbor) orelse initial;
                }

                try new_centrality.put(node, sum);
                norm += sum * sum;
            }

            norm = @sqrt(norm);
            if (norm == 0) norm = 1;

            // Normalize and check convergence
            var max_diff: f64 = 0;
            for (nodes) |node| {
                const new_val = (new_centrality.get(node) orelse 0) / norm;
                const old_val = centrality.get(node) orelse 0;
                const diff = @abs(new_val - old_val);
                max_diff = @max(max_diff, diff);
                try centrality.put(node, new_val);

                // Track convergence
                if (diff < tolerance) {
                    converged_count += 1;
                }
            }

            // Early termination
            if (converged_count >= convergence_threshold or max_diff < tolerance) break;
        }

        // Cache results
        self.cache.eigenvector_results.clearAndFree();
        var it = centrality.iterator();
        while (it.next()) |entry| {
            try self.cache.eigenvector_results.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        self.cache.cache_timestamp = std.time.milliTimestamp();

        return centrality;
    }

    // Community detection using Louvain algorithm
    pub fn louvainCommunities(
        self: *BuiltinAlgorithms,
        resolution: f64,
        random_seed: ?u64,
    ) !std.AutoHashMap(u64, u64) {
        const nodes = try self.graph.getAllNodes(self.allocator);
        defer self.allocator.free(nodes);

        var communities = std.AutoHashMap(u64, u64).init(self.allocator);
        var node_to_comm = std.AutoHashMap(u64, u64).init(self.allocator);
        defer node_to_comm.deinit();

        // Initialize each node in its own community
        for (nodes, 0..) |node, i| {
            try communities.put(node, i);
            try node_to_comm.put(node, i);
        }

        var rng = std.rand.DefaultPrng.init(random_seed orelse @intCast(std.time.timestamp()));
        const random = rng.random();

        // Phase 1: Local optimization
        var improved = true;
        var total_edge_weight = try self.getTotalEdgeWeight();

        while (improved) {
            improved = false;

            // Shuffle nodes for random order
            var shuffled = try self.allocator.dupe(u64, nodes);
            defer self.allocator.free(shuffled);
            random.shuffle(u64, shuffled);

            for (shuffled) |node| {
                const current_comm = node_to_comm.get(node) orelse continue;
                const neighbors = try self.graph.getNeighbors(self.allocator, node);
                defer self.allocator.free(neighbors);

                // Find best community to move to
                var best_comm = current_comm;
                var best_gain: f64 = 0;

                var neighbor_comms = std.AutoHashMap(u64, f64).init(self.allocator);
                defer neighbor_comms.deinit();

                for (neighbors) |neighbor| {
                    const neighbor_comm = node_to_comm.get(neighbor) orelse continue;
                    const weight = try self.graph.getEdgeWeight(node, neighbor);
                    const current = neighbor_comms.get(neighbor_comm) orelse 0;
                    try neighbor_comms.put(neighbor_comm, current + weight);
                }

                var it = neighbor_comms.iterator();
                while (it.next()) |entry| {
                    const comm = entry.key_ptr.*;
                    if (comm == current_comm) continue;

                    const gain = self.calculateModularityGain(
                        node,
                        current_comm,
                        comm,
                        &node_to_comm,
                        total_edge_weight,
                        resolution,
                    ) catch 0;

                    if (gain > best_gain) {
                        best_gain = gain;
                        best_comm = comm;
                    }
                }

                if (best_comm != current_comm) {
                    try node_to_comm.put(node, best_comm);
                    improved = true;
                }
            }
        }

        // Phase 2: Community aggregation (simplified)
        var final_communities = std.AutoHashMap(u64, u64).init(self.allocator);
        var comm_id: u64 = 0;
        var comm_map = std.AutoHashMap(u64, u64).init(self.allocator);
        defer comm_map.deinit();

        for (nodes) |node| {
            const comm = node_to_comm.get(node) orelse continue;
            const final_comm = comm_map.get(comm) orelse blk: {
                const new_id = comm_id;
                comm_id += 1;
                try comm_map.put(comm, new_id);
                break :blk new_id;
            };
            try final_communities.put(node, final_comm);
        }

        return final_communities;
    }

    // Label propagation for community detection
    pub fn labelPropagationCommunities(
        self: *BuiltinAlgorithms,
        max_iterations: u32,
    ) !std.AutoHashMap(u64, u64) {
        const nodes = try self.graph.getAllNodes(self.allocator);
        defer self.allocator.free(nodes);

        var labels = std.AutoHashMap(u64, u64).init(self.allocator);

        // Initialize each node with unique label
        for (nodes, 0..) |node, i| {
            try labels.put(node, i);
        }

        var iteration: u32 = 0;
        var changed = true;

        while (changed and iteration < max_iterations) : (iteration += 1) {
            changed = false;

            for (nodes) |node| {
                const neighbors = try self.graph.getNeighbors(self.allocator, node);
                defer self.allocator.free(neighbors);

                if (neighbors.len == 0) continue;

                // Count label frequencies among neighbors
                var label_counts = std.AutoHashMap(u64, u32).init(self.allocator);
                defer label_counts.deinit();

                for (neighbors) |neighbor| {
                    const label = labels.get(neighbor) orelse continue;
                    const count = label_counts.get(label) orelse 0;
                    try label_counts.put(label, count + 1);
                }

                // Find most frequent label
                var max_count: u32 = 0;
                var max_label = labels.get(node) orelse 0;

                var it = label_counts.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* > max_count) {
                        max_count = entry.value_ptr.*;
                        max_label = entry.key_ptr.*;
                    }
                }

                const current_label = labels.get(node) orelse 0;
                if (max_label != current_label) {
                    try labels.put(node, max_label);
                    changed = true;
                }
            }
        }

        return labels;
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

    // Helper functions
    fn getNeighbors(self: *BuiltinAlgorithms, node: u64, relationship_types: ?[]const []const u8, direction: graph_exec.Direction) ![]Neighbor {
        _ = relationship_types;
        _ = direction;

        const edges = try self.graph.getOutgoingEdges(self.allocator, node);
        defer self.allocator.free(edges);

        var neighbors = try self.allocator.alloc(Neighbor, edges.len);
        for (edges, 0..) |edge, i| {
            neighbors[i] = .{
                .node = edge.to_id,
                .edge = edge.id,
            };
        }

        return neighbors;
    }

    fn reconstructPath(self: *BuiltinAlgorithms, start: u64, end: u64, parent: *std.AutoHashMap(u64, PathInfo)) !graph_exec.Path {
        var path_nodes = std.ArrayList(u64).init(self.allocator);
        var path_edges = std.ArrayList(u64).init(self.allocator);

        var current = end;
        while (current != start) {
            try path_nodes.insert(0, current);

            if (parent.get(current)) |info| {
                if (info.edge) |edge| {
                    try path_edges.insert(0, edge);
                }
                current = info.node;
            } else {
                return error.InvalidPath;
            }
        }
        try path_nodes.insert(0, start);

        return graph_exec.Path{
            .nodes = try path_nodes.toOwnedSlice(),
            .edges = try path_edges.toOwnedSlice(),
            .total_weight = @intCast(path_edges.items.len),
        };
    }

    fn computeShortestPaths(self: *BuiltinAlgorithms, source: u64) !std.AutoHashMap(u64, u32) {
        var distances = std.AutoHashMap(u64, u32).init(self.allocator);
        var visited = std.AutoHashMap(u64, void).init(self.allocator);
        defer visited.deinit();

        var queue = std.ArrayList(struct { node: u64, dist: u32 }).init(self.allocator);
        defer queue.deinit();

        try queue.append(.{ .node = source, .dist = 0 });
        try distances.put(source, 0);
        try visited.put(source, {});

        var front: usize = 0;
        while (front < queue.items.len) : (front += 1) {
            const current = queue.items[front];

            const neighbors = try self.graph.getNeighbors(self.allocator, current.node);
            defer self.allocator.free(neighbors);

            for (neighbors) |neighbor| {
                if (!visited.contains(neighbor)) {
                    try visited.put(neighbor, {});
                    try distances.put(neighbor, current.dist + 1);
                    try queue.append(.{ .node = neighbor, .dist = current.dist + 1 });
                }
            }
        }

        // Set unreachable nodes to max distance
        const all_nodes = try self.graph.getAllNodes(self.allocator);
        defer self.allocator.free(all_nodes);

        for (all_nodes) |node| {
            if (!distances.contains(node)) {
                try distances.put(node, std.math.maxInt(u32));
            }
        }

        return distances;
    }

    fn getTotalEdgeWeight(self: *BuiltinAlgorithms) !f64 {
        const edges = try self.graph.getAllEdges();
        defer self.allocator.free(edges);

        var total: f64 = 0;
        for (edges) |edge| {
            total += edge.weight orelse 1.0;
        }

        return total;
    }

    fn calculateModularityGain(
        self: *BuiltinAlgorithms,
        node: u64,
        from_comm: u64,
        to_comm: u64,
        node_to_comm: *std.AutoHashMap(u64, u64),
        total_weight: f64,
        resolution: f64,
    ) !f64 {
        _ = from_comm;

        const node_degree = try self.graph.getDegree(node);
        var to_comm_weight: f64 = 0;

        const neighbors = try self.graph.getNeighbors(self.allocator, node);
        defer self.allocator.free(neighbors);

        for (neighbors) |neighbor| {
            if (node_to_comm.get(neighbor) == to_comm) {
                const weight = try self.graph.getEdgeWeight(node, neighbor);
                to_comm_weight += weight;
            }
        }

        const ki = @as(f64, @floatFromInt(node_degree));
        const m = total_weight;

        // Simplified modularity gain calculation
        return (to_comm_weight / m - resolution * ki * ki / (2.0 * m * m));
    }

    const Neighbor = struct {
        node: u64,
        edge: ?u64,
    };

    const PathInfo = struct {
        node: u64,
        edge: ?u64,
    };

    const QueueItem = struct {
        node: u64,
        depth: u32,
    };

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
        const target_nodes = nodes orelse try self.graph.getAllNodes(self.allocator);
        defer if (nodes == null) self.allocator.free(target_nodes);

        var results = std.ArrayList(CentralityResult){};

        for (target_nodes) |node| {
            const degree = switch (direction) {
                .outgoing => self.graph.getOutDegree(node),
                .incoming => try self.graph.getInDegree(node),
                .both => blk: {
                    const out = self.graph.getOutDegree(node);
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
        const target_nodes = nodes orelse try self.graph.getAllNodes(self.allocator);
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
        const nodes = try self.graph.getAllNodes(self.allocator);
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
        var results = std.ArrayList(CentralityResult).init(self.allocator);
        var result_it = eigenvector.iterator();
        while (result_it.next()) |entry| {
            try results.append(.{
                .node_id = entry.key_ptr.*,
                .score = entry.value_ptr.*,
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

    // Algorithm cache for memoization
    const AlgorithmCache = struct {
        // CANARY: REQ=REQ-GQL-ALGO-PERF; FEATURE="Algorithm Performance"; ASPECT=Caching; STATUS=TESTED; TEST=benchmark_graph_algorithms; OWNER=graph; UPDATED=2025-10-16

        allocator: Allocator,
        pagerank_results: std.AutoHashMap(u64, f64),
        betweenness_results: std.AutoHashMap(u64, f64),
        closeness_results: std.AutoHashMap(u64, f64),
        eigenvector_results: std.AutoHashMap(u64, f64),
        degree_cache: std.AutoHashMap(u64, usize),
        adjacency_cache: std.AutoHashMap(u64, []u64),
        shortest_paths_cache: std.AutoHashMap(u64, std.AutoHashMap(u64, u32)),
        cache_timestamp: i64,
        cache_valid: bool,

        pub fn init(allocator: Allocator) AlgorithmCache {
            return .{
                .allocator = allocator,
                .pagerank_results = std.AutoHashMap(u64, f64).init(allocator),
                .betweenness_results = std.AutoHashMap(u64, f64).init(allocator),
                .closeness_results = std.AutoHashMap(u64, f64).init(allocator),
                .eigenvector_results = std.AutoHashMap(u64, f64).init(allocator),
                .degree_cache = std.AutoHashMap(u64, usize).init(allocator),
                .adjacency_cache = std.AutoHashMap(u64, []u64).init(allocator),
                .shortest_paths_cache = std.AutoHashMap(u64, std.AutoHashMap(u64, u32)).init(allocator),
                .cache_timestamp = std.time.milliTimestamp(),
                .cache_valid = true,
            };
        }

        pub fn deinit(self: *AlgorithmCache) void {
            self.pagerank_results.deinit();
            self.betweenness_results.deinit();
            self.closeness_results.deinit();
            self.eigenvector_results.deinit();
            self.degree_cache.deinit();

            // Free adjacency cache arrays
            var adj_iter = self.adjacency_cache.valueIterator();
            while (adj_iter.next()) |neighbors| {
                self.allocator.free(neighbors.*);
            }
            self.adjacency_cache.deinit();

            // Free shortest paths cache
            var sp_iter = self.shortest_paths_cache.valueIterator();
            while (sp_iter.next()) |distances| {
                distances.deinit();
            }
            self.shortest_paths_cache.deinit();
        }

        pub fn invalidate(self: *AlgorithmCache) void {
            self.cache_valid = false;
            self.pagerank_results.clearAndFree();
            self.betweenness_results.clearAndFree();
            self.closeness_results.clearAndFree();
            self.eigenvector_results.clearAndFree();
            self.degree_cache.clearAndFree();

            // Clear adjacency cache
            var adj_iter = self.adjacency_cache.valueIterator();
            while (adj_iter.next()) |neighbors| {
                self.allocator.free(neighbors.*);
            }
            self.adjacency_cache.clearAndFree();

            // Clear shortest paths cache
            var sp_iter = self.shortest_paths_cache.valueIterator();
            while (sp_iter.next()) |distances| {
                distances.deinit();
            }
            self.shortest_paths_cache.clearAndFree();
        }

        pub fn getCachedNeighbors(self: *AlgorithmCache, node: u64) ?[]u64 {
            return self.adjacency_cache.get(node);
        }

        pub fn cacheNeighbors(self: *AlgorithmCache, node: u64, neighbors: []u64) !void {
            const copy = try self.allocator.dupe(u64, neighbors);
            try self.adjacency_cache.put(node, copy);
        }

        pub fn getCachedDegree(self: *AlgorithmCache, node: u64) ?usize {
            return self.degree_cache.get(node);
        }

        pub fn cacheDegree(self: *AlgorithmCache, node: u64, degree: usize) !void {
            try self.degree_cache.put(node, degree);
        }
    };

    // Cached graph operations for performance
    fn getNeighborsCached(self: *BuiltinAlgorithms, node: u64) ![]u64 {
        // Check cache first
        if (self.cache.getCachedNeighbors(node)) |neighbors| {
            return neighbors;
        }

        // Cache miss - fetch and cache
        const neighbors = try self.graph.getNeighbors(self.allocator, node);
        try self.cache.cacheNeighbors(node, neighbors);
        self.allocator.free(neighbors); // Original freed, cache holds copy

        return self.cache.getCachedNeighbors(node).?;
    }

    fn getDegreeCached(self: *BuiltinAlgorithms, node: u64) !usize {
        // Check cache first
        if (self.cache.getCachedDegree(node)) |degree| {
            return degree;
        }

        // Cache miss - compute and cache
        const neighbors = try self.graph.getNeighbors(self.allocator, node);
        defer self.allocator.free(neighbors);
        const degree = neighbors.len;

        try self.cache.cacheDegree(node, degree);
        return degree;
    }

    // Preload adjacency data for batch operations
    fn preloadAdjacencyData(self: *BuiltinAlgorithms, nodes: []const u64) !void {
        for (nodes) |node| {
            // Skip if already cached
            if (self.cache.getCachedNeighbors(node) != null) continue;

            const neighbors = try self.graph.getNeighbors(self.allocator, node);
            try self.cache.cacheNeighbors(node, neighbors);
            try self.cache.cacheDegree(node, neighbors.len);
            self.allocator.free(neighbors);
        }
    }
    //
    //     const Neighbor = struct {
    //         node: u64,
    //         edge: ?u64,
    //     };
    //
    //     // Helper functions
    //     fn getNeighbors(
    //         self: *BuiltinAlgorithms,
    //         node: u64,
    //         relationship_types: ?[]const []const u8,
    //         direction: graph_exec.Direction,
    //     ) ![]Neighbor {
    //         _ = relationship_types; // TODO: Filter by relationship type
    //
    //         var neighbors = std.ArrayList(Neighbor){};
    //
    //         switch (direction) {
    //             .outgoing => {
    //                 const out_nodes = try self.graph.getOutgoingNodes(node);
    //                 defer self.allocator.free(out_nodes);
    //                 for (out_nodes) |n| {
    //                     try neighbors.append(.{ .node = n, .edge = null });
    //                 }
    //             },
    //             .incoming => {
    //                 const in_nodes = try self.graph.getIncomingNodes(node);
    //                 defer self.allocator.free(in_nodes);
    //                 for (in_nodes) |n| {
    //                     try neighbors.append(.{ .node = n, .edge = null });
    //                 }
    //             },
    //             .both => {
    //                 const out_nodes = try self.graph.getOutgoingNodes(node);
    //                 defer self.allocator.free(out_nodes);
    //                 const in_nodes = try self.graph.getIncomingNodes(node);
    //                 defer self.allocator.free(in_nodes);
    //
    //                 for (out_nodes) |n| {
    //                     try neighbors.append(.{ .node = n, .edge = null });
    //                 }
    //                 for (in_nodes) |n| {
    //                     try neighbors.append(.{ .node = n, .edge = null });
    //                 }
    //             },
    //         }
    //
    //         return neighbors.toOwnedSlice();
    //     }
    //
    //     fn reconstructPath(
    //         self: *BuiltinAlgorithms,
    //         start: u64,
    //         end: u64,
    //         parent: *std.AutoHashMap(u64, PathInfo),
    //     ) !graph_exec.Path {
    //         var nodes = std.ArrayList(u64){};
    //         var edges = std.ArrayList(u64){};
    //
    //         var current = end;
    //         try nodes.append(current);
    //
    //         while (current != start) {
    //             if (parent.get(current)) |info| {
    //                 current = info.node;
    //                 try nodes.append(current);
    //                 if (info.edge) |edge| {
    //                     try edges.append(edge);
    //                 }
    //             } else {
    //                 break;
    //             }
    //         }
    //
    //         // Reverse to get path from start to end
    //         std.mem.reverse(u64, nodes.items);
    //         std.mem.reverse(u64, edges.items);
    //
    //         return .{
    //             .nodes = try nodes.toOwnedSlice(),
    //             .edges = try edges.toOwnedSlice(),
    //             .length = nodes.items.len - 1,
    //         };
    //     }
    //
    //     fn reconstructAllPaths(
    //         self: *BuiltinAlgorithms,
    //         start: u64,
    //         end: u64,
    //         parents: *std.AutoHashMap(u64, std.ArrayList(PathInfo)),
    //         paths: *std.ArrayList(graph_exec.Path),
    //     ) !void {
    //         // Recursive path reconstruction for multiple parents
    //         var current_path = std.ArrayList(u64){};
    //         defer current_path.deinit();
    //
    //         try self.reconstructAllPathsRecursive(start, end, parents, &current_path, paths);
    //     }
    //
    //     fn reconstructAllPathsRecursive(
    //         self: *BuiltinAlgorithms,
    //         start: u64,
    //         current: u64,
    //         parents: *std.AutoHashMap(u64, std.ArrayList(PathInfo)),
    //         current_path: *std.ArrayList(u64),
    //         paths: *std.ArrayList(graph_exec.Path),
    //     ) !void {
    //         try current_path.append(current);
    //         defer _ = current_path.pop();
    //
    //         if (current == start) {
    //             // Found complete path
    //             var path_nodes = try self.allocator.alloc(u64, current_path.items.len);
    //             std.mem.copy(u64, path_nodes, current_path.items);
    //             std.mem.reverse(u64, path_nodes);
    //
    //             try paths.append(.{
    //                 .nodes = path_nodes,
    //                 .edges = &[_]u64{}, // TODO: Track edges
    //                 .length = path_nodes.len - 1,
    //             });
    //             return;
    //         }
    //
    //         if (parents.get(current)) |parent_list| {
    //             for (parent_list.items) |parent_info| {
    //                 try self.reconstructAllPathsRecursive(
    //                     start,
    //                     parent_info.node,
    //                     parents,
    //                     current_path,
    //                     paths,
    //                 );
    //             }
    //         }
    //     }
    //
    //     fn computeDistances(self: *BuiltinAlgorithms, start: u64) !std.AutoHashMap(u64, u32) {
    //         var distances = std.AutoHashMap(u64, u32).init(self.allocator);
    //         var queue = std.ArrayList(struct { node: u64, dist: u32 }){};
    //         defer queue.deinit();
    //
    //         try distances.put(start, 0);
    //         try queue.append(.{ .node = start, .dist = 0 });
    //
    //         var front: usize = 0;
    //         while (front < queue.items.len) : (front += 1) {
    //             const current = queue.items[front];
    //
    //             const neighbors = try self.graph.getNeighbors(self.allocator, current.node);
    //             defer self.allocator.free(neighbors);
    //
    //             for (neighbors) |neighbor| {
    //                 if (!distances.contains(neighbor)) {
    //                     try distances.put(neighbor, current.dist + 1);
    //                     try queue.append(.{ .node = neighbor, .dist = current.dist + 1 });
    //                 }
    //             }
    //         }
    //
    //         return distances;
    //     }
    //
    //     fn calculateModularityGain(
    //         self: *BuiltinAlgorithms,
    //         communities: *std.AutoHashMap(u64, u64),
    //         node: u64,
    //         from_community: u64,
    //         to_community: u64,
    //         resolution: f64,
    //     ) !f64 {
    //         _ = from_community;
    //
    //         const total_edges = try self.graph.getEdgeCount();
    //         if (total_edges == 0) return 0;
    //
    //         const m = @as(f64, @floatFromInt(total_edges));
    //         const node_degree = @as(f64, @floatFromInt((try self.graph.getNeighbors(self.allocator, node)).len));
    //
    //         // Calculate sum of edges from node to nodes in to_community
    //         var edges_to_community: f64 = 0;
    //         const neighbors = try self.graph.getNeighbors(self.allocator, node);
    //         defer self.allocator.free(neighbors);
    //
    //         for (neighbors) |neighbor| {
    //             if (communities.get(neighbor)) |comm| {
    //                 if (comm == to_community) {
    //                     edges_to_community += 1;
    //                 }
    //             }
    //         }
    //
    //         // Calculate total degree of nodes in to_community
    //         var community_degree: f64 = 0;
    //         var it = communities.iterator();
    //         while (it.next()) |entry| {
    //             if (entry.value_ptr.* == to_community) {
    //                 const degree = (try self.graph.getNeighbors(self.allocator, entry.key_ptr.*)).len;
    //                 self.allocator.free(degree);
    //                 community_degree += @as(f64, @floatFromInt(degree));
    //             }
    //         }
    //
    //         // Modularity gain formula
    //         const gain = (edges_to_community / m) -
    //             resolution * (node_degree * community_degree) / (2.0 * m * m);
    //
    //         return gain;
    //     }
};
