const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../storage/interface.zig");

// Advanced path algorithms for graph traversal
// GAP-0084: Extended to collect edge IDs during path finding
// CANARY: REQ=REQ-GQL-PATH-001; FEATURE="PathEdgeCollection"; ASPECT=GraphTraversal; STATUS=IMPL; UPDATED=2026-01-10
pub const PathAlgorithms = struct {
    allocator: Allocator,

    pub const Path = struct {
        nodes: []u64,
        edges: []u64, // GAP-0084: Now populated during path reconstruction
        weight: f64,
    };

    pub const CentralityResult = struct {
        node_id: u64,
        score: f64,
    };

    pub const Community = struct {
        id: u64,
        nodes: []u64,
        modularity: f64,
    };

    pub fn init(allocator: Allocator) PathAlgorithms {
        return .{ .allocator = allocator };
    }

    // Dijkstra's shortest path algorithm with edge collection
    // GAP-0084: Now collects edge IDs for RELATIONSHIPS(path) function support
    pub fn dijkstraShortestPath(
        self: *PathAlgorithms,
        graph: *storage.GraphStorage,
        start: u64,
        end: u64,
        edge_weights: ?std.AutoHashMap(u64, f64),
    ) !?Path {
        var distances = std.AutoHashMap(u64, f64).init(self.allocator);
        defer distances.deinit();
        var previous = std.AutoHashMap(u64, u64).init(self.allocator);
        defer previous.deinit();
        // GAP-0084: Track edge used to reach each node
        var previous_edge = std.AutoHashMap(u64, u64).init(self.allocator);
        defer previous_edge.deinit();
        var visited = std.AutoHashMap(u64, void).init(self.allocator);
        defer visited.deinit();

        // Priority queue for nodes to visit
        const QueueItem = struct {
            node: u64,
            distance: f64,

            fn lessThan(_: void, a: @This(), b: @This()) std.math.Order {
                return std.math.order(a.distance, b.distance);
            }
        };

        var queue = std.PriorityQueue(QueueItem, void, QueueItem.lessThan).init(self.allocator, {});
        defer queue.deinit();

        try distances.put(start, 0);
        try queue.add(.{ .node = start, .distance = 0 });

        while (queue.removeOrNull()) |item| {
            if (visited.contains(item.node)) continue;
            try visited.put(item.node, {});

            if (item.node == end) {
                // Reconstruct path with edges
                var path_nodes = std.ArrayList(u64).init(self.allocator);
                var path_edges = std.ArrayList(u64).init(self.allocator);
                var current = end;

                while (current != start) {
                    try path_nodes.append(current);
                    // GAP-0084: Collect edge ID used to reach this node
                    if (previous_edge.get(current)) |edge_id| {
                        try path_edges.append(edge_id);
                    }
                    current = previous.get(current) orelse break;
                }
                try path_nodes.append(start);

                // Reverse to get start-to-end order
                std.mem.reverse(u64, path_nodes.items);
                std.mem.reverse(u64, path_edges.items);

                return Path{
                    .nodes = try path_nodes.toOwnedSlice(),
                    .edges = try path_edges.toOwnedSlice(), // GAP-0084: Now populated
                    .weight = item.distance,
                };
            }

            // Get neighbors with edge info
            const neighbors = try graph.getNeighbors(item.node);
            defer self.allocator.free(neighbors);

            // GAP-0084: Try to get edge-aware neighbor info if available
            const edge_info = if (graph.getEdgeInfo) |get_edges| try get_edges(item.node) else null;

            for (neighbors, 0..) |neighbor, idx| {
                if (visited.contains(neighbor)) continue;

                const edge_weight = if (edge_weights) |weights|
                    weights.get(neighbor) orelse 1.0
                else
                    1.0;

                const new_distance = item.distance + edge_weight;
                const current_distance = distances.get(neighbor) orelse std.math.inf(f64);

                if (new_distance < current_distance) {
                    try distances.put(neighbor, new_distance);
                    try previous.put(neighbor, item.node);
                    // GAP-0084: Store edge ID if available
                    if (edge_info) |info| {
                        if (idx < info.len) {
                            try previous_edge.put(neighbor, info[idx].edge_id);
                        }
                    } else {
                        // Synthetic edge ID based on node pair for fallback
                        const synthetic_edge_id = (item.node << 32) | neighbor;
                        try previous_edge.put(neighbor, synthetic_edge_id);
                    }
                    try queue.add(.{ .node = neighbor, .distance = new_distance });
                }
            }
        }

        return null; // No path found
    }

    // PageRank algorithm
    pub fn pageRank(
        self: *PathAlgorithms,
        graph: *storage.GraphStorage,
        damping_factor: f64,
        max_iterations: usize,
        tolerance: f64,
    ) ![]CentralityResult {
        const nodes = try graph.getAllNodes();
        defer self.allocator.free(nodes);

        const n = @as(f64, @floatFromInt(nodes.len));
        var ranks = std.AutoHashMap(u64, f64).init(self.allocator);
        defer ranks.deinit();
        var new_ranks = std.AutoHashMap(u64, f64).init(self.allocator);
        defer new_ranks.deinit();

        // Initialize ranks
        for (nodes) |node| {
            try ranks.put(node, 1.0 / n);
        }

        var iteration: usize = 0;
        while (iteration < max_iterations) : (iteration += 1) {
            // Calculate new ranks
            for (nodes) |node| {
                var rank: f64 = (1.0 - damping_factor) / n;

                // Get incoming edges
                const incoming = try graph.getIncomingEdges(node);
                defer self.allocator.free(incoming);

                for (incoming) |source| {
                    const out_degree = try graph.getOutDegree(source);
                    if (out_degree > 0) {
                        const source_rank = ranks.get(source) orelse (1.0 / n);
                        rank += damping_factor * source_rank / @as(f64, @floatFromInt(out_degree));
                    }
                }

                try new_ranks.put(node, rank);
            }

            // Check convergence
            var max_diff: f64 = 0;
            for (nodes) |node| {
                const old_rank = ranks.get(node).?;
                const new_rank = new_ranks.get(node).?;
                max_diff = @max(max_diff, @abs(new_rank - old_rank));
            }

            // Swap ranks
            const temp = ranks;
            ranks = new_ranks;
            new_ranks = temp;
            new_ranks.clearRetainingCapacity();

            if (max_diff < tolerance) break;
        }

        // Convert to results
        var results = std.ArrayList(CentralityResult){};
        var it = ranks.iterator();
        while (it.next()) |entry| {
            try results.append(.{
                .node_id = entry.key_ptr.*,
                .score = entry.value_ptr.*,
            });
        }

        return results.toOwnedSlice();
    }
};
