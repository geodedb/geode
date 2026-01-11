const std = @import("std");
const Allocator = std.mem.Allocator;

pub const EmbeddingDimension = u32;
pub const Embedding = []f32;
pub const NodeId = u64;
pub const EdgeId = u64;

pub const MLAlgorithm = enum {
    node2vec,
    graphsage,
    gcn, // Graph Convolutional Network
    gat, // Graph Attention Network
    deepwalk,
    line,
    fasttext,
    pagerank,
    louvain,
    label_propagation,
    link_prediction,
    node_classification,
};

pub const Node2VecParams = struct {
    dimensions: EmbeddingDimension = 128,
    walk_length: u32 = 80,
    num_walks: u32 = 10,
    p: f64 = 1.0, // Return parameter
    q: f64 = 1.0, // In-out parameter
    window_size: u32 = 10,
    iterations: u32 = 1,
    workers: u32 = 4,
    learning_rate: f32 = 0.01,
    min_count: u32 = 1,
    seed: ?u64 = null,
};

pub const GraphSAGEParams = struct {
    dimensions: EmbeddingDimension = 256,
    aggregator: enum { mean, max, lstm, pool } = .mean,
    layers: u32 = 2,
    batch_size: u32 = 512,
    learning_rate: f32 = 0.001,
    epochs: u32 = 10,
    dropout: f32 = 0.5,
    weight_decay: f32 = 0.0001,
};

pub const LinkPredictionParams = struct {
    method: enum {
        hadamard,
        l1,
        l2,
        average,
        cosine,
        adamic_adar,
        jaccard,
        preferential_attachment,
        resource_allocation,
    } = .hadamard,
    threshold: f32 = 0.5,
    negative_sampling_ratio: f32 = 1.0,
    embeddings: ?[]Embedding = null,
};

pub const NodeClassificationParams = struct {
    algorithm: enum {
        logistic_regression,
        random_forest,
        neural_network,
        svm,
        knn,
    } = .logistic_regression,
    train_split: f32 = 0.8,
    validation_split: f32 = 0.1,
    test_split: f32 = 0.1,
    features: ?[][]f32 = null,
    labels: ?[]u32 = null,
};

pub const PageRankParams = struct {
    damping_factor: f32 = 0.85,
    max_iterations: u32 = 100,
    tolerance: f32 = 1e-6,
    personalization: ?std.AutoHashMap(NodeId, f32) = null,
};

pub const LouvainParams = struct {
    resolution: f32 = 1.0,
    randomize: bool = true,
    seed: ?u64 = null,
    max_iterations: u32 = 100,
};

pub const CommunityDetectionResult = struct {
    communities: std.AutoHashMap(NodeId, u32),
    modularity: f32,
    num_communities: u32,
};

pub const MLEngine = struct {
    allocator: Allocator,
    graph: *GraphData,
    embeddings: std.AutoHashMap(NodeId, Embedding),
    models: std.StringHashMap(*anyopaque),

    const Self = @This();

    pub fn init(allocator: Allocator, graph: *GraphData) Self {
        return Self{
            .allocator = allocator,
            .graph = graph,
            .embeddings = std.AutoHashMap(NodeId, Embedding).init(allocator),
            .models = std.StringHashMap(*anyopaque).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.embeddings.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.embeddings.deinit();
        self.models.deinit();
    }

    // Node2Vec implementation
    pub fn node2vec(self: *Self, params: Node2VecParams) !std.AutoHashMap(NodeId, Embedding) {
        var result = std.AutoHashMap(NodeId, Embedding).init(self.allocator);
        errdefer result.deinit();

        // Initialize random walk sampler
        var walker = try RandomWalker.init(self.allocator, self.graph, params.p, params.q);
        defer walker.deinit();

        // Generate walks for each node
        var walks = std.ArrayList([]NodeId).init(self.allocator);
        defer {
            for (walks.items) |walk| {
                self.allocator.free(walk);
            }
            walks.deinit();
        }

        var node_it = self.graph.nodes.iterator();
        while (node_it.next()) |entry| {
            const node_id = entry.key_ptr.*;

            var i: u32 = 0;
            while (i < params.num_walks) : (i += 1) {
                const walk = try walker.walk(node_id, params.walk_length);
                try walks.append(walk);
            }
        }

        // Train Skip-gram model
        var skipgram = try SkipGram.init(
            self.allocator,
            params.dimensions,
            params.window_size,
            params.learning_rate,
        );
        defer skipgram.deinit();

        try skipgram.train(walks.items, params.iterations);

        // Extract embeddings
        node_it = self.graph.nodes.iterator();
        while (node_it.next()) |entry| {
            const node_id = entry.key_ptr.*;
            const embedding = try skipgram.getEmbedding(node_id);
            const embedding_copy = try self.allocator.alloc(f32, embedding.len);
            @memcpy(embedding_copy, embedding);
            try result.put(node_id, embedding_copy);
        }

        return result;
    }

    // PageRank implementation
    pub fn pagerank(self: *Self, params: PageRankParams) !std.AutoHashMap(NodeId, f32) {
        var scores = std.AutoHashMap(NodeId, f32).init(self.allocator);
        var new_scores = std.AutoHashMap(NodeId, f32).init(self.allocator);
        defer new_scores.deinit();

        const num_nodes = self.graph.nodes.count();
        const initial_score = 1.0 / @as(f32, @floatFromInt(num_nodes));

        // Initialize scores
        var node_it = self.graph.nodes.iterator();
        while (node_it.next()) |entry| {
            const node_id = entry.key_ptr.*;
            if (params.personalization) |pers| {
                try scores.put(node_id, pers.get(node_id) orelse initial_score);
            } else {
                try scores.put(node_id, initial_score);
            }
        }

        // Iterative computation
        var iteration: u32 = 0;
        while (iteration < params.max_iterations) : (iteration += 1) {
            var max_diff: f32 = 0.0;

            node_it = self.graph.nodes.iterator();
            while (node_it.next()) |entry| {
                const node_id = entry.key_ptr.*;
                var rank_sum: f32 = 0.0;

                // Sum contributions from incoming edges
                if (self.graph.incoming_edges.get(node_id)) |incoming| {
                    for (incoming.items) |edge_id| {
                        const edge = self.graph.edges.get(edge_id).?;
                        const source_score = scores.get(edge.source).?;
                        const out_degree = self.graph.getOutDegree(edge.source);
                        rank_sum += source_score / @as(f32, @floatFromInt(out_degree));
                    }
                }

                const new_score = (1.0 - params.damping_factor) / @as(f32, @floatFromInt(num_nodes)) +
                    params.damping_factor * rank_sum;

                const old_score = scores.get(node_id).?;
                max_diff = @max(max_diff, @abs(new_score - old_score));

                try new_scores.put(node_id, new_score);
            }

            // Swap scores
            const temp = scores;
            scores = new_scores;
            new_scores = temp;
            new_scores.clearRetainingCapacity();

            if (max_diff < params.tolerance) {
                break;
            }
        }

        return scores;
    }

    // Link prediction
    pub fn linkPrediction(self: *Self, params: LinkPredictionParams) !LinkPredictionResult {
        var predictions = std.ArrayList(EdgePrediction).init(self.allocator);
        defer predictions.deinit();

        var node_it = self.graph.nodes.iterator();
        while (node_it.next()) |entry1| {
            const node1 = entry1.key_ptr.*;

            var node_it2 = self.graph.nodes.iterator();
            while (node_it2.next()) |entry2| {
                const node2 = entry2.key_ptr.*;

                if (node1 >= node2) continue; // Avoid duplicates
                if (self.graph.hasEdge(node1, node2)) continue; // Skip existing edges

                const score = try self.computeLinkScore(node1, node2, params);

                if (score >= params.threshold) {
                    try predictions.append(EdgePrediction{
                        .source = node1,
                        .target = node2,
                        .score = score,
                    });
                }
            }
        }

        // Sort by score
        std.sort.pdq(EdgePrediction, predictions.items, {}, EdgePrediction.compareScore);

        return LinkPredictionResult{
            .predictions = try predictions.toOwnedSlice(),
        };
    }

    fn computeLinkScore(self: *Self, node1: NodeId, node2: NodeId, params: LinkPredictionParams) !f32 {
        switch (params.method) {
            .hadamard => {
                if (params.embeddings) |embeddings| {
                    const emb1 = embeddings[node1];
                    const emb2 = embeddings[node2];
                    var score: f32 = 0.0;
                    for (emb1, emb2) |v1, v2| {
                        score += v1 * v2;
                    }
                    return score;
                }
                return 0.0;
            },
            .cosine => {
                if (params.embeddings) |embeddings| {
                    const emb1 = embeddings[node1];
                    const emb2 = embeddings[node2];
                    return cosineSimilarity(emb1, emb2);
                }
                return 0.0;
            },
            .adamic_adar => {
                return self.adamicAdarScore(node1, node2);
            },
            .jaccard => {
                return self.jaccardScore(node1, node2);
            },
            .preferential_attachment => {
                const deg1 = self.graph.getOutDegree(node1);
                const deg2 = self.graph.getOutDegree(node2);
                return @as(f32, @floatFromInt(deg1 * deg2));
            },
            .resource_allocation => {
                return self.resourceAllocationScore(node1, node2);
            },
            else => return 0.0,
        }
    }

    fn adamicAdarScore(self: *Self, node1: NodeId, node2: NodeId) f32 {
        var score: f32 = 0.0;
        const neighbors1 = self.graph.getNeighbors(node1);
        const neighbors2 = self.graph.getNeighbors(node2);

        for (neighbors1) |n1| {
            for (neighbors2) |n2| {
                if (n1 == n2) {
                    const degree = self.graph.getOutDegree(n1);
                    if (degree > 1) {
                        score += 1.0 / @log(@as(f32, @floatFromInt(degree)));
                    }
                }
            }
        }

        return score;
    }

    fn jaccardScore(self: *Self, node1: NodeId, node2: NodeId) f32 {
        const neighbors1 = self.graph.getNeighbors(node1);
        const neighbors2 = self.graph.getNeighbors(node2);

        var intersection: u32 = 0;
        for (neighbors1) |n1| {
            for (neighbors2) |n2| {
                if (n1 == n2) intersection += 1;
            }
        }

        const union_size = neighbors1.len + neighbors2.len - intersection;
        if (union_size == 0) return 0.0;

        return @as(f32, @floatFromInt(intersection)) / @as(f32, @floatFromInt(union_size));
    }

    fn resourceAllocationScore(self: *Self, node1: NodeId, node2: NodeId) f32 {
        var score: f32 = 0.0;
        const neighbors1 = self.graph.getNeighbors(node1);
        const neighbors2 = self.graph.getNeighbors(node2);

        for (neighbors1) |n1| {
            for (neighbors2) |n2| {
                if (n1 == n2) {
                    const degree = self.graph.getOutDegree(n1);
                    if (degree > 0) {
                        score += 1.0 / @as(f32, @floatFromInt(degree));
                    }
                }
            }
        }

        return score;
    }

    // Community detection using Louvain algorithm
    pub fn louvain(self: *Self, params: LouvainParams) !CommunityDetectionResult {
        var communities = std.AutoHashMap(NodeId, u32).init(self.allocator);
        var community_weights = std.AutoHashMap(u32, f32).init(self.allocator);
        defer community_weights.deinit();

        // Initialize each node in its own community
        var community_id: u32 = 0;
        var node_it = self.graph.nodes.iterator();
        while (node_it.next()) |entry| {
            const node_id = entry.key_ptr.*;
            try communities.put(node_id, community_id);
            try community_weights.put(community_id, 1.0);
            community_id += 1;
        }

        var improved = true;
        var iteration: u32 = 0;

        while (improved and iteration < params.max_iterations) : (iteration += 1) {
            improved = false;

            // Phase 1: Local optimization
            node_it = self.graph.nodes.iterator();
            while (node_it.next()) |entry| {
                const node_id = entry.key_ptr.*;
                const current_community = communities.get(node_id).?;

                var best_community = current_community;
                var best_gain: f32 = 0.0;

                // Check neighboring communities
                const neighbors = self.graph.getNeighbors(node_id);
                for (neighbors) |neighbor| {
                    const neighbor_community = communities.get(neighbor).?;
                    if (neighbor_community == current_community) continue;

                    const gain = self.modularityGain(node_id, neighbor_community, &communities);
                    if (gain > best_gain) {
                        best_gain = gain;
                        best_community = neighbor_community;
                    }
                }

                if (best_community != current_community) {
                    try communities.put(node_id, best_community);
                    improved = true;
                }
            }
        }

        // Calculate final modularity
        const modularity = try self.calculateModularity(&communities);

        // Count communities
        var unique_communities = std.AutoHashMap(u32, void).init(self.allocator);
        defer unique_communities.deinit();

        var comm_it = communities.iterator();
        while (comm_it.next()) |entry| {
            try unique_communities.put(entry.value_ptr.*, {});
        }

        return CommunityDetectionResult{
            .communities = communities,
            .modularity = modularity,
            .num_communities = unique_communities.count(),
        };
    }

    /// Calculate modularity gain for moving a node to a different community
    /// CANARY: REQ=REQ-ML-MODULARITY-001; FEATURE="Louvain Modularity Gain"; STATUS=IMPL; OWNER=ml; UPDATED=2026-01-10
    /// GAP-0050: Implements actual modularity gain calculation using standard formula
    /// ΔQ = [k_i,in / m - (Σ_tot * k_i) / (2m²)] where:
    ///   k_i,in = sum of edge weights from node i to nodes in target community
    ///   Σ_tot = sum of all edge weights incident to nodes in target community
    ///   k_i = degree of node i (sum of its edge weights)
    ///   m = total edge weight in graph / 2
    fn modularityGain(self: *Self, node: NodeId, target_community: u32, communities: *std.AutoHashMap(NodeId, u32)) f32 {
        // Calculate total edge weight (m)
        var total_weight: f32 = 0.0;
        var edge_it = self.graph.edges.iterator();
        while (edge_it.next()) |entry| {
            total_weight += entry.value_ptr.weight;
        }
        // For undirected graph, m = total_weight / 2
        const m = total_weight / 2.0;
        if (m == 0.0) return 0.0;

        // Calculate k_i (degree of node)
        var k_i: f32 = 0.0;
        if (self.graph.outgoing_edges.get(node)) |out_edges| {
            for (out_edges.items) |edge_id| {
                if (self.graph.edges.get(edge_id)) |edge| {
                    k_i += edge.weight;
                }
            }
        }
        if (self.graph.incoming_edges.get(node)) |in_edges| {
            for (in_edges.items) |edge_id| {
                if (self.graph.edges.get(edge_id)) |edge| {
                    k_i += edge.weight;
                }
            }
        }

        // Calculate k_i,in (edges from node to target community)
        var k_i_in: f32 = 0.0;
        if (self.graph.outgoing_edges.get(node)) |out_edges| {
            for (out_edges.items) |edge_id| {
                if (self.graph.edges.get(edge_id)) |edge| {
                    if (communities.get(edge.target)) |target_comm| {
                        if (target_comm == target_community) {
                            k_i_in += edge.weight;
                        }
                    }
                }
            }
        }
        if (self.graph.incoming_edges.get(node)) |in_edges| {
            for (in_edges.items) |edge_id| {
                if (self.graph.edges.get(edge_id)) |edge| {
                    if (communities.get(edge.source)) |source_comm| {
                        if (source_comm == target_community) {
                            k_i_in += edge.weight;
                        }
                    }
                }
            }
        }

        // Calculate Σ_tot (total weight incident to target community)
        var sigma_tot: f32 = 0.0;
        var node_it = communities.iterator();
        while (node_it.next()) |entry| {
            if (entry.value_ptr.* != target_community) continue;
            const comm_node = entry.key_ptr.*;
            if (self.graph.outgoing_edges.get(comm_node)) |out_edges| {
                for (out_edges.items) |edge_id| {
                    if (self.graph.edges.get(edge_id)) |edge| {
                        sigma_tot += edge.weight;
                    }
                }
            }
        }

        // Calculate modularity gain: ΔQ = k_i,in / m - (Σ_tot * k_i) / (2m²)
        const delta_q = (k_i_in / m) - (sigma_tot * k_i) / (2.0 * m * m);
        return delta_q;
    }

    /// Calculate overall modularity of current community assignment
    /// CANARY: REQ=REQ-ML-MODULARITY-002; FEATURE="Graph Modularity Calculation"; STATUS=IMPL; OWNER=ml; UPDATED=2026-01-10
    /// GAP-0050: Implements actual modularity calculation using standard formula
    /// Q = (1/2m) * Σ_ij [A_ij - (k_i * k_j) / (2m)] * δ(c_i, c_j)
    fn calculateModularity(self: *Self, communities: *std.AutoHashMap(NodeId, u32)) !f32 {
        // Calculate total edge weight (m)
        var total_weight: f32 = 0.0;
        var edge_it = self.graph.edges.iterator();
        while (edge_it.next()) |entry| {
            total_weight += entry.value_ptr.weight;
        }
        const m = total_weight / 2.0;
        if (m == 0.0) return 0.0;

        // Pre-calculate node degrees
        var degrees = std.AutoHashMap(NodeId, f32).init(self.allocator);
        defer degrees.deinit();

        var node_it = self.graph.nodes.iterator();
        while (node_it.next()) |entry| {
            const node_id = entry.key_ptr.*;
            var k_i: f32 = 0.0;
            if (self.graph.outgoing_edges.get(node_id)) |out_edges| {
                for (out_edges.items) |edge_id| {
                    if (self.graph.edges.get(edge_id)) |edge| {
                        k_i += edge.weight;
                    }
                }
            }
            if (self.graph.incoming_edges.get(node_id)) |in_edges| {
                for (in_edges.items) |edge_id| {
                    if (self.graph.edges.get(edge_id)) |edge| {
                        k_i += edge.weight;
                    }
                }
            }
            try degrees.put(node_id, k_i);
        }

        // Calculate modularity: Q = (1/2m) * Σ [A_ij - (k_i * k_j)/(2m)] * δ(c_i, c_j)
        var modularity: f32 = 0.0;
        edge_it = self.graph.edges.iterator();
        while (edge_it.next()) |entry| {
            const edge = entry.value_ptr.*;
            const c_i = communities.get(edge.source) orelse continue;
            const c_j = communities.get(edge.target) orelse continue;

            // Only count if same community (δ = 1)
            if (c_i != c_j) continue;

            const k_i = degrees.get(edge.source) orelse 0.0;
            const k_j = degrees.get(edge.target) orelse 0.0;

            // Q_edge = A_ij - (k_i * k_j) / (2m)
            modularity += edge.weight - (k_i * k_j) / (2.0 * m);
        }

        // Normalize by 1/(2m)
        return modularity / (2.0 * m);
    }
};

// Helper structures
const RandomWalker = struct {
    allocator: Allocator,
    graph: *GraphData,
    p: f64,
    q: f64,

    pub fn init(allocator: Allocator, graph: *GraphData, p: f64, q: f64) !RandomWalker {
        return RandomWalker{
            .allocator = allocator,
            .graph = graph,
            .p = p,
            .q = q,
        };
    }

    pub fn deinit(self: *RandomWalker) void {
        _ = self;
    }

    pub fn walk(self: *RandomWalker, start: NodeId, length: u32) ![]NodeId {
        var path = try self.allocator.alloc(NodeId, length);
        path[0] = start;

        var i: u32 = 1;
        var current = start;
        var previous: ?NodeId = null;

        while (i < length) : (i += 1) {
            const neighbors = self.graph.getNeighbors(current);
            if (neighbors.len == 0) break;

            const next = self.sampleNext(current, previous, neighbors);
            path[i] = next;
            previous = current;
            current = next;
        }

        return path[0..i];
    }

    fn sampleNext(self: *RandomWalker, current: NodeId, previous: ?NodeId, neighbors: []NodeId) NodeId {
        _ = self;
        _ = current;
        _ = previous;
        // Simplified sampling
        const idx = std.crypto.random.int(usize) % neighbors.len;
        return neighbors[idx];
    }
};

const SkipGram = struct {
    allocator: Allocator,
    dimensions: u32,
    window_size: u32,
    learning_rate: f32,
    embeddings: std.AutoHashMap(NodeId, []f32),

    pub fn init(allocator: Allocator, dimensions: u32, window_size: u32, learning_rate: f32) !SkipGram {
        return SkipGram{
            .allocator = allocator,
            .dimensions = dimensions,
            .window_size = window_size,
            .learning_rate = learning_rate,
            .embeddings = std.AutoHashMap(NodeId, []f32).init(allocator),
        };
    }

    pub fn deinit(self: *SkipGram) void {
        var it = self.embeddings.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.embeddings.deinit();
    }

    pub fn train(self: *SkipGram, walks: [][]NodeId, iterations: u32) !void {
        _ = iterations;

        // Initialize embeddings randomly
        for (walks) |walk| {
            for (walk) |node| {
                if (!self.embeddings.contains(node)) {
                    const embedding = try self.allocator.alloc(f32, self.dimensions);
                    for (embedding) |*v| {
                        v.* = (std.crypto.random.float(f32) - 0.5) * 0.1;
                    }
                    try self.embeddings.put(node, embedding);
                }
            }
        }

        // Training loop (simplified)
        for (walks) |walk| {
            for (walk, 0..) |node, i| {
                const start = if (i > self.window_size) i - self.window_size else 0;
                const end = @min(i + self.window_size + 1, walk.len);

                for (walk[start..end], 0..) |context_node, j| {
                    if (start + j == i) continue; // Skip self
                    try self.updateEmbeddings(node, context_node);
                }
            }
        }
    }

    fn updateEmbeddings(self: *SkipGram, target: NodeId, context: NodeId) !void {
        const target_emb = self.embeddings.get(target).?;
        const context_emb = self.embeddings.get(context).?;

        // Simplified gradient update
        for (target_emb, context_emb) |*t, *c| {
            const gradient = (t.* - c.*) * self.learning_rate;
            t.* -= gradient;
            c.* += gradient;
        }
    }

    pub fn getEmbedding(self: *SkipGram, node: NodeId) ![]f32 {
        return self.embeddings.get(node) orelse return error.NodeNotFound;
    }
};

const EdgePrediction = struct {
    source: NodeId,
    target: NodeId,
    score: f32,

    pub fn compareScore(context: void, a: EdgePrediction, b: EdgePrediction) bool {
        _ = context;
        return a.score > b.score;
    }
};

const LinkPredictionResult = struct {
    predictions: []EdgePrediction,
};

// Placeholder graph data structure
const GraphData = struct {
    nodes: std.AutoHashMap(NodeId, void),
    edges: std.AutoHashMap(EdgeId, Edge),
    outgoing_edges: std.AutoHashMap(NodeId, std.ArrayList(EdgeId)),
    incoming_edges: std.AutoHashMap(NodeId, std.ArrayList(EdgeId)),

    const Edge = struct {
        source: NodeId,
        target: NodeId,
        weight: f32 = 1.0,
    };

    // CANARY: REQ=REQ-ML-NEIGHBORS-001; FEATURE="GraphData.getNeighbors"; ASPECT=NeighborLookup; STATUS=IMPL; OWNER=ml; UPDATED=2026-01-11
    pub fn getNeighbors(self: *GraphData, node: NodeId) []NodeId {
        // Return neighbor nodes from outgoing edges
        if (self.outgoing_edges.get(node)) |edges| {
            // Collect target nodes from edges
            const result = std.heap.page_allocator.alloc(NodeId, edges.items.len) catch return &[_]NodeId{};
            for (edges.items, 0..) |edge, i| {
                result[i] = edge.target;
            }
            return result;
        }
        return &[_]NodeId{};
    }

    pub fn getOutDegree(self: *GraphData, node: NodeId) u32 {
        if (self.outgoing_edges.get(node)) |edges| {
            return @intCast(edges.items.len);
        }
        return 0;
    }

    // CANARY: REQ=REQ-ML-HASEDGE-001; FEATURE="GraphData.hasEdge"; ASPECT=EdgeLookup; STATUS=IMPL; OWNER=ml; UPDATED=2026-01-10
    pub fn hasEdge(self: *GraphData, source: NodeId, target: NodeId) bool {
        // Look up the source node in the outgoing_edges map
        if (self.outgoing_edges.get(source)) |edges| {
            // Search for the target in the edge list
            for (edges.items) |edge| {
                if (edge.target == target) {
                    return true;
                }
            }
        }
        return false;
    }
};

fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
    var dot: f32 = 0.0;
    var norm_a: f32 = 0.0;
    var norm_b: f32 = 0.0;

    for (a, b) |va, vb| {
        dot += va * vb;
        norm_a += va * va;
        norm_b += vb * vb;
    }

    if (norm_a == 0.0 or norm_b == 0.0) return 0.0;
    return dot / (@sqrt(norm_a) * @sqrt(norm_b));
}

// GDS-style procedure interface
pub const GDSProcedure = struct {
    name: []const u8,
    execute: *const fn (allocator: Allocator, graph: *GraphData, params: anytype) anyerror!void,
};

pub const gds_procedures = [_]GDSProcedure{
    .{ .name = "gds.node2vec.stream", .execute = executeNode2Vec },
    .{ .name = "gds.pageRank.stream", .execute = executePageRank },
    .{ .name = "gds.louvain.stream", .execute = executeLouvain },
    .{ .name = "gds.linkPrediction.mutate", .execute = executeLinkPrediction },
};

fn executeNode2Vec(allocator: Allocator, graph: *GraphData, params: anytype) !void {
    _ = allocator;
    _ = graph;
    _ = params;
    // Implementation would stream results
}

fn executePageRank(allocator: Allocator, graph: *GraphData, params: anytype) !void {
    _ = allocator;
    _ = graph;
    _ = params;
    // Implementation would stream results
}

fn executeLouvain(allocator: Allocator, graph: *GraphData, params: anytype) !void {
    _ = allocator;
    _ = graph;
    _ = params;
    // Implementation would stream results
}

fn executeLinkPrediction(allocator: Allocator, graph: *GraphData, params: anytype) !void {
    _ = allocator;
    _ = graph;
    _ = params;
    // Implementation would mutate graph with predictions
}

test "Node2Vec basic" {
    const allocator = std.testing.allocator;

    var graph = GraphData{
        .nodes = std.AutoHashMap(NodeId, void).init(allocator),
        .edges = std.AutoHashMap(EdgeId, Edge).init(allocator),
        .outgoing_edges = std.AutoHashMap(NodeId, std.ArrayList(EdgeId)).init(allocator),
        .incoming_edges = std.AutoHashMap(NodeId, std.ArrayList(EdgeId)).init(allocator),
    };
    defer {
        graph.nodes.deinit();
        graph.edges.deinit();
        graph.outgoing_edges.deinit();
        graph.incoming_edges.deinit();
    }

    // Add some nodes
    try graph.nodes.put(1, {});
    try graph.nodes.put(2, {});
    try graph.nodes.put(3, {});

    var ml_engine = MLEngine.init(allocator, &graph);
    defer ml_engine.deinit();

    const params = Node2VecParams{};
    const embeddings = try ml_engine.node2vec(params);
    defer {
        var it = embeddings.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        embeddings.deinit();
    }

    try std.testing.expect(embeddings.count() > 0);
}

test "PageRank computation" {
    const allocator = std.testing.allocator;

    var graph = GraphData{
        .nodes = std.AutoHashMap(NodeId, void).init(allocator),
        .edges = std.AutoHashMap(EdgeId, Edge).init(allocator),
        .outgoing_edges = std.AutoHashMap(NodeId, std.ArrayList(EdgeId)).init(allocator),
        .incoming_edges = std.AutoHashMap(NodeId, std.ArrayList(EdgeId)).init(allocator),
    };
    defer {
        graph.nodes.deinit();
        graph.edges.deinit();
        graph.outgoing_edges.deinit();
        graph.incoming_edges.deinit();
    }

    // Add nodes
    try graph.nodes.put(1, {});
    try graph.nodes.put(2, {});
    try graph.nodes.put(3, {});

    var ml_engine = MLEngine.init(allocator, &graph);
    defer ml_engine.deinit();

    const params = PageRankParams{};
    const scores = try ml_engine.pagerank(params);
    defer scores.deinit();

    try std.testing.expect(scores.count() == 3);
}

test "Community detection" {
    const allocator = std.testing.allocator;

    var graph = GraphData{
        .nodes = std.AutoHashMap(NodeId, void).init(allocator),
        .edges = std.AutoHashMap(EdgeId, Edge).init(allocator),
        .outgoing_edges = std.AutoHashMap(NodeId, std.ArrayList(EdgeId)).init(allocator),
        .incoming_edges = std.AutoHashMap(NodeId, std.ArrayList(EdgeId)).init(allocator),
    };
    defer {
        graph.nodes.deinit();
        graph.edges.deinit();
        graph.outgoing_edges.deinit();
        graph.incoming_edges.deinit();
    }

    // Add nodes
    for (1..10) |i| {
        try graph.nodes.put(i, {});
    }

    var ml_engine = MLEngine.init(allocator, &graph);
    defer ml_engine.deinit();

    const params = LouvainParams{};
    const result = try ml_engine.louvain(params);
    defer result.communities.deinit();

    try std.testing.expect(result.num_communities > 0);
    try std.testing.expect(result.modularity >= 0.0 and result.modularity <= 1.0);
}
