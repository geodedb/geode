// CANARY: REQ=REQ-ML-EMBEDDINGS-001; FEATURE="Graph Embeddings Integration"; ASPECT=CoreSystem; STATUS=TESTED; TEST=TestCANARY_ML_EMBEDDINGS_001_CoreSystem; OWNER=ml; UPDATED=2025-10-05
// CANARY: REQ=REQ-ML-EMBEDDINGS-002; FEATURE="Node2Vec Algorithm"; ASPECT=Implementation; STATUS=TESTED; TEST=TestCANARY_ML_EMBEDDINGS_002_Node2Vec; OWNER=ml; UPDATED=2025-10-05
// CANARY: REQ=REQ-ML-EMBEDDINGS-003; FEATURE="Graph Neural Networks"; ASPECT=GraphSAGE; STATUS=TESTED; TEST=TestCANARY_ML_EMBEDDINGS_003_GraphSAGE; OWNER=ml; UPDATED=2025-10-05

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
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const expect = std.testing.expect;

// Use lib.zig to access other modules properly
const geode = @import("../lib.zig");
const user_management = @import("../security/user_management.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=ML; STATUS=EXEMPT; OWNER=ml; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("ml");
const Attr = logging.Attr;

/// Configuration for embedding dimensions and algorithm parameters
pub const EmbeddingConfig = struct {
    dimensions: u32 = 128,
    learning_rate: f64 = 0.01,
    epochs: u32 = 100,
    batch_size: u32 = 32,
    negative_samples: u32 = 5,
    walk_length: u32 = 80,
    num_walks: u32 = 10,
    window_size: u32 = 10,

    // Node2Vec specific parameters
    p: f64 = 1.0, // Return parameter - controls likelihood of revisiting previous node
    q: f64 = 1.0, // In-out parameter - controls exploration vs exploitation

    // GraphSAGE specific parameters
    neighbor_samples: u32 = 25,
    aggregator_type: AggregatorType = .mean,

    // Training parameters
    min_learning_rate: f64 = 0.0001,
    convergence_threshold: f64 = 0.001,
    max_iterations: u32 = 1000,
};

/// Types of aggregation functions for GraphSAGE
pub const AggregatorType = enum {
    mean, // Average of neighbor embeddings
    max, // Element-wise maximum
    lstm, // LSTM aggregation (advanced)
    pool, // Pooling aggregation
    attention, // Attention-based aggregation
};

/// ML algorithm types supported
pub const MLAlgorithm = enum {
    node2vec, // Random walk based embeddings
    graphsage, // Inductive graph neural network
    gcn, // Graph Convolutional Network
    gat, // Graph Attention Network
    deepwalk, // Deep walk algorithm
    line, // Large-scale Information Network Embedding
    pagerank, // PageRank centrality
    louvain, // Community detection
    label_propagation, // Semi-supervised learning
    link_prediction, // Link prediction tasks
    node_classification, // Node classification tasks
};

/// Embedding vector storage and management
pub const EmbeddingVector = struct {
    node_id: u64,
    embedding: []f32,
    algorithm: MLAlgorithm,
    created_at: i64,
    updated_at: i64,

    pub fn deinit(self: *EmbeddingVector, allocator: Allocator) void {
        allocator.free(self.embedding);
    }

    /// Calculate cosine similarity with another embedding
    pub fn cosineSimilarity(self: *const EmbeddingVector, other: *const EmbeddingVector) f64 {
        if (self.embedding.len != other.embedding.len) return 0.0;

        var dot_product: f64 = 0.0;
        var norm_a: f64 = 0.0;
        var norm_b: f64 = 0.0;

        for (self.embedding, other.embedding) |a, b| {
            dot_product += a * b;
            norm_a += a * a;
            norm_b += b * b;
        }

        const magnitude = @sqrt(norm_a * norm_b);
        return if (magnitude > 0.0) dot_product / magnitude else 0.0;
    }

    /// Calculate Euclidean distance to another embedding
    pub fn euclideanDistance(self: *const EmbeddingVector, other: *const EmbeddingVector) f64 {
        if (self.embedding.len != other.embedding.len) return std.math.inf(f64);

        var sum: f64 = 0.0;
        for (self.embedding, other.embedding) |a, b| {
            const diff = a - b;
            sum += diff * diff;
        }
        return @sqrt(sum);
    }
};

/// Random walk state for Node2Vec algorithm
pub const RandomWalk = struct {
    path: ArrayList(u64),
    current_node: u64,
    previous_node: ?u64,
    p: f64, // Return parameter
    q: f64, // In-out parameter

    pub fn init(allocator: Allocator, start_node: u64, p: f64, q: f64) RandomWalk {
        var path = ArrayList(u64).init(allocator);
        path.append(start_node) catch {};

        return RandomWalk{
            .path = path,
            .current_node = start_node,
            .previous_node = null,
            .p = p,
            .q = q,
        };
    }

    pub fn deinit(self: *RandomWalk) void {
        self.path.deinit();
    }

    /// Calculate transition probability for Node2Vec biased walk
    pub fn transitionProbability(self: *const RandomWalk, target_node: u64, graph: *const geode.graph_common.GraphStore) f64 {
        if (self.previous_node == null) return 1.0;

        const prev = self.previous_node.?;

        // Distance from previous node to target
        if (target_node == prev) {
            // Returning to previous node
            return 1.0 / self.p;
        } else if (graph.hasEdge(prev, target_node)) {
            // Target is neighbor of previous node
            return 1.0;
        } else {
            // Target is not directly connected to previous node
            return 1.0 / self.q;
        }
    }
};

/// Training context for embedding algorithms
pub const TrainingContext = struct {
    epoch: u32,
    batch: u32,
    loss: f64,
    learning_rate: f64,
    convergence_score: f64,

    pub fn updateLearningRate(self: *TrainingContext, config: *const EmbeddingConfig) void {
        // Exponential decay of learning rate
        const decay_rate = 0.95;
        self.learning_rate = @max(config.min_learning_rate, config.learning_rate * std.math.pow(f64, decay_rate, @as(f64, @floatFromInt(self.epoch))));
    }

    pub fn hasConverged(self: *const TrainingContext, config: *const EmbeddingConfig) bool {
        return self.convergence_score < config.convergence_threshold;
    }
};

/// Graph Embeddings Integration Manager
pub const GraphEmbeddingsManager = struct {
    allocator: Allocator,
    embeddings: AutoHashMap(u64, EmbeddingVector), // node_id -> embedding
    algorithm_registry: AutoHashMap(MLAlgorithm, AlgorithmImplementation),
    index_manager: ?*geode.index.IndexManager,
    config: EmbeddingConfig,
    statistics: EmbeddingStatistics,
    training_context: ?TrainingContext,
    // GAP-0081: Store graph reference for inductive learning
    // CANARY: REQ=REQ-GRAPHSAGE-INDUCTIVE-001; FEATURE="GraphSAGE Inductive Learning"; ASPECT=GraphStore; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=ml; UPDATED=2026-01-10
    trained_graph: ?*const geode.graph_common.GraphStore = null,
    // Learned aggregation weights for GraphSAGE (per layer)
    aggregation_weights: ?[][]f32 = null,
    num_layers: u32 = 2,

    pub const AlgorithmImplementation = struct {
        train_fn: *const fn (*GraphEmbeddingsManager, *const geode.graph_common.GraphStore, EmbeddingConfig) anyerror!void,
        predict_fn: *const fn (*GraphEmbeddingsManager, u64) anyerror![]f32,
        update_fn: *const fn (*GraphEmbeddingsManager, u64, []const f32) anyerror!void,
        similarity_fn: *const fn (*GraphEmbeddingsManager, u64, u64) anyerror!f64,
    };

    pub const EmbeddingStatistics = struct {
        total_embeddings: u64 = 0,
        algorithms_trained: u32 = 0,
        total_training_time_ms: u64 = 0,
        average_embedding_quality: f64 = 0.0,
        last_training_timestamp: i64 = 0,
        memory_usage_bytes: u64 = 0,

        pub fn updateMemoryUsage(self: *EmbeddingStatistics, embeddings: *const AutoHashMap(u64, EmbeddingVector)) void {
            var total_bytes: u64 = 0;
            var iterator = embeddings.iterator();
            while (iterator.next()) |entry| {
                total_bytes += @sizeOf(EmbeddingVector) + entry.value_ptr.embedding.len * @sizeOf(f32);
            }
            self.memory_usage_bytes = total_bytes;
        }
    };

    pub fn init(allocator: Allocator, config: EmbeddingConfig) !GraphEmbeddingsManager {
        var manager = GraphEmbeddingsManager{
            .allocator = allocator,
            .embeddings = AutoHashMap(u64, EmbeddingVector).init(allocator),
            .algorithm_registry = AutoHashMap(MLAlgorithm, AlgorithmImplementation).init(allocator),
            .index_manager = null,
            .config = config,
            .statistics = .{},
            .training_context = null,
        };

        // Register algorithm implementations
        try manager.registerAlgorithms();

        log.info("Initialized Graph Embeddings Manager with {} dimensions", .{config.dimensions});
        return manager;
    }

    pub fn deinit(self: *GraphEmbeddingsManager) void {
        // Clean up all embeddings
        var iterator = self.embeddings.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.embeddings.deinit();
        self.algorithm_registry.deinit();
    }

    /// Register algorithm implementations
    fn registerAlgorithms(self: *GraphEmbeddingsManager) !void {
        // Node2Vec implementation
        try self.algorithm_registry.put(.node2vec, AlgorithmImplementation{
            .train_fn = trainNode2Vec,
            .predict_fn = predictNode2Vec,
            .update_fn = updateNode2Vec,
            .similarity_fn = calculateSimilarity,
        });

        // GraphSAGE implementation
        try self.algorithm_registry.put(.graphsage, AlgorithmImplementation{
            .train_fn = trainGraphSAGE,
            .predict_fn = predictGraphSAGE,
            .update_fn = updateGraphSAGE,
            .similarity_fn = calculateSimilarity,
        });

        // DeepWalk implementation
        try self.algorithm_registry.put(.deepwalk, AlgorithmImplementation{
            .train_fn = trainDeepWalk,
            .predict_fn = predictDeepWalk,
            .update_fn = updateDeepWalk,
            .similarity_fn = calculateSimilarity,
        });

        log.info("Registered {} ML algorithms", .{self.algorithm_registry.count()});
    }

    /// Train embeddings using specified algorithm.
    /// ML training accesses all nodes cross-tenant (null tenant_id) and requires Admin role
    /// when authentication is enabled.
    pub fn trainEmbeddings(self: *GraphEmbeddingsManager, graph: *const geode.graph_common.GraphStore, algorithm: MLAlgorithm, custom_config: ?EmbeddingConfig, caller_role: ?user_management.Role) !void {
        // ML training is a cross-tenant admin-level operation (getAllNodesForTenant with null tenant_id).
        // Require Admin role when authentication is enabled.
        const auth_enabled = user_management.isAuthEnabled();
        if (auth_enabled) {
            if (caller_role) |role| {
                if (role != .Admin) return error.InsufficientPrivileges;
            } else {
                // No role provided but auth is enabled — deny access
                return error.InsufficientPrivileges;
            }
        }

        const config = custom_config orelse self.config;
        const start_time = compat_milliTimestamp();

        // Initialize training context
        self.training_context = TrainingContext{
            .epoch = 0,
            .batch = 0,
            .loss = std.math.inf(f64),
            .learning_rate = config.learning_rate,
            .convergence_score = std.math.inf(f64),
        };

        log.info("Starting {} training with {} dimensions, {} epochs", .{ algorithm, config.dimensions, config.epochs });

        // Get algorithm implementation
        const implementation = self.algorithm_registry.get(algorithm) orelse {
            return error.AlgorithmNotImplemented;
        };

        // Train the algorithm
        try implementation.train_fn(self, graph, config);

        // Update statistics
        const training_time = compat_milliTimestamp() - start_time;
        self.statistics.algorithms_trained += 1;
        self.statistics.total_training_time_ms += @intCast(training_time);
        self.statistics.last_training_timestamp = compat_milliTimestamp();
        self.statistics.total_embeddings = self.embeddings.count();
        self.statistics.updateMemoryUsage(&self.embeddings);

        // Calculate average embedding quality (simplified metric)
        self.statistics.average_embedding_quality = self.calculateAverageQuality();

        log.info("Completed {} training in {}ms, generated {} embeddings", .{ algorithm, training_time, self.embeddings.count() });
    }

    /// Get embedding for a specific node
    pub fn getEmbedding(self: *const GraphEmbeddingsManager, node_id: u64) ?*const EmbeddingVector {
        return self.embeddings.getPtr(node_id);
    }

    /// Find similar nodes using embedding similarity
    pub fn findSimilarNodes(self: *const GraphEmbeddingsManager, node_id: u64, k: u32, similarity_threshold: f64) !ArrayList(struct { node_id: u64, similarity: f64 }) {
        var results = ArrayList(struct { node_id: u64, similarity: f64 }).init(self.allocator);

        const query_embedding = self.embeddings.get(node_id) orelse return error.NodeNotFound;

        var iterator = self.embeddings.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.* == node_id) continue;

            const similarity = query_embedding.cosineSimilarity(entry.value_ptr);
            if (similarity >= similarity_threshold) {
                try results.append(.{ .node_id = entry.key_ptr.*, .similarity = similarity });
            }
        }

        // Sort by similarity (descending)
        std.sort.pdq(struct { node_id: u64, similarity: f64 }, results.items, {}, struct {
            fn lessThan(_: void, a: struct { node_id: u64, similarity: f64 }, b: struct { node_id: u64, similarity: f64 }) bool {
                return a.similarity > b.similarity;
            }
        }.lessThan);

        // Limit to k results
        if (results.items.len > k) {
            results.shrinkRetainingCapacity(k);
        }

        return results;
    }

    /// Predict embedding for a new node (using trained model)
    pub fn predictEmbedding(self: *GraphEmbeddingsManager, node_id: u64, algorithm: MLAlgorithm) ![]f32 {
        const implementation = self.algorithm_registry.get(algorithm) orelse {
            return error.AlgorithmNotImplemented;
        };

        return try implementation.predict_fn(self, node_id);
    }

    /// Update existing embedding
    pub fn updateEmbedding(self: *GraphEmbeddingsManager, node_id: u64, new_embedding: []const f32) !void {
        var embedding_entry = self.embeddings.getPtr(node_id) orelse return error.NodeNotFound;

        if (embedding_entry.embedding.len != new_embedding.len) {
            return error.DimensionMismatch;
        }

        // Copy new embedding values
        std.mem.copyForwards(f32, embedding_entry.embedding, new_embedding);
        embedding_entry.updated_at = compat_milliTimestamp();

        log.debug("Updated embedding for node {}", .{node_id});
    }

    /// Calculate average quality metric for all embeddings
    fn calculateAverageQuality(self: *const GraphEmbeddingsManager) f64 {
        if (self.embeddings.count() == 0) return 0.0;

        var total_magnitude: f64 = 0.0;
        var iterator = self.embeddings.valueIterator();

        while (iterator.next()) |embedding| {
            var magnitude: f64 = 0.0;
            for (embedding.embedding) |value| {
                magnitude += value * value;
            }
            total_magnitude += @sqrt(magnitude);
        }

        return total_magnitude / @as(f64, @floatFromInt(self.embeddings.count()));
    }

    /// Get comprehensive statistics
    pub fn getStatistics(self: *const GraphEmbeddingsManager) EmbeddingStatistics {
        return self.statistics;
    }

    /// Connect to index manager for vector similarity search
    pub fn connectIndexManager(self: *GraphEmbeddingsManager, idx_manager: *geode.index.IndexManager) void {
        self.index_manager = idx_manager;
        log.info("Connected to IndexManager for vector similarity search");
    }
};

// Algorithm Implementation Functions

/// Node2Vec training implementation
fn trainNode2Vec(manager: *GraphEmbeddingsManager, graph: *const geode.graph_common.GraphStore, config: EmbeddingConfig) !void {
    log.info("Training Node2Vec algorithm with p={d:.2}, q={d:.2}", .{ config.p, config.q });

    // Initialize embeddings for all nodes (null = cross-tenant, admin-level operation)
    const nodes = try graph.getAllNodesForTenant(manager.allocator, null);
    defer manager.allocator.free(nodes);

    for (nodes) |node_id| {
        const embedding = try manager.allocator.alloc(f32, config.dimensions);

        // Initialize with small random values
        var prng = std.rand.DefaultPrng.init(@intCast(compat_milliTimestamp()));
        for (embedding) |*value| {
            value.* = (prng.random().float(f32) - 0.5) * 0.1;
        }

        try manager.embeddings.put(node_id, EmbeddingVector{
            .node_id = node_id,
            .embedding = embedding,
            .algorithm = .node2vec,
            .created_at = compat_milliTimestamp(),
            .updated_at = compat_milliTimestamp(),
        });
    }

    // Generate random walks and train embeddings
    for (0..config.epochs) |epoch| {
        if (manager.training_context) |*ctx| {
            ctx.epoch = @intCast(epoch);
            ctx.updateLearningRate(&config);
        }

        // Perform random walks for each node
        for (nodes) |start_node| {
            for (0..config.num_walks) |_| {
                var walk = RandomWalk.init(manager.allocator, start_node, config.p, config.q);
                defer walk.deinit();

                // Generate walk of specified length
                try generateRandomWalk(&walk, graph, config.walk_length);

                // Train embeddings using skip-gram model
                try trainSkipGram(manager, walk.path.items, config);
            }
        }

        log.debug("Completed epoch {}/{}", .{ epoch + 1, config.epochs });
    }
}

/// GraphSAGE training implementation
fn trainGraphSAGE(manager: *GraphEmbeddingsManager, graph: *const geode.graph_common.GraphStore, config: EmbeddingConfig) !void {
    log.info("Training GraphSAGE algorithm with {} neighbor samples", .{config.neighbor_samples});

    // GAP-0081: Store graph reference for inductive learning on unseen nodes
    manager.trained_graph = graph;

    // Initialize aggregation weights for inductive inference
    if (manager.aggregation_weights == null) {
        manager.aggregation_weights = try manager.allocator.alloc([]f32, manager.num_layers);
        for (manager.aggregation_weights.?) |*layer_weights| {
            layer_weights.* = try manager.allocator.alloc(f32, config.dimensions * 2);
            var prng = std.rand.DefaultPrng.init(@intCast(compat_milliTimestamp()));
            for (layer_weights.*) |*w| {
                w.* = prng.random().floatNorm(f32) * 0.1;
            }
        }
    }

    // null = cross-tenant, admin-level ML operation
    const nodes = try graph.getAllNodesForTenant(manager.allocator, null);
    defer manager.allocator.free(nodes);

    // Initialize embeddings
    for (nodes) |node_id| {
        const embedding = try manager.allocator.alloc(f32, config.dimensions);

        // Initialize with Xavier initialization
        var prng = std.rand.DefaultPrng.init(@intCast(compat_milliTimestamp() + node_id));
        const fan_in = @as(f32, @floatFromInt(config.dimensions));
        const xavier_std = @sqrt(2.0 / fan_in);

        for (embedding) |*value| {
            value.* = prng.random().floatNorm(f32) * xavier_std;
        }

        try manager.embeddings.put(node_id, EmbeddingVector{
            .node_id = node_id,
            .embedding = embedding,
            .algorithm = .graphsage,
            .created_at = compat_milliTimestamp(),
            .updated_at = compat_milliTimestamp(),
        });
    }

    // Training iterations
    for (0..config.epochs) |epoch| {
        if (manager.training_context) |*ctx| {
            ctx.epoch = @intCast(epoch);
            ctx.updateLearningRate(&config);
        }

        // Sample neighbors and aggregate features
        for (nodes) |node_id| {
            try aggregateNeighborFeatures(manager, graph, node_id, config);
        }

        log.debug("Completed GraphSAGE epoch {}/{}", .{ epoch + 1, config.epochs });
    }
}

/// DeepWalk training implementation (simplified Node2Vec with p=1, q=1)
fn trainDeepWalk(manager: *GraphEmbeddingsManager, graph: *const geode.graph_common.GraphStore, config: EmbeddingConfig) !void {
    log.info("Training DeepWalk algorithm");

    // DeepWalk is Node2Vec with p=1, q=1 (uniform random walks)
    var deepwalk_config = config;
    deepwalk_config.p = 1.0;
    deepwalk_config.q = 1.0;

    try trainNode2Vec(manager, graph, deepwalk_config);
}

// Helper functions for algorithm implementations

/// Generate a biased random walk for Node2Vec
fn generateRandomWalk(walk: *RandomWalk, graph: *const geode.graph_common.GraphStore, walk_length: u32) !void {
    var current = walk.current_node;

    for (1..walk_length) |_| {
        const neighbors = try graph.getNeighbors(walk.path.allocator, current);
        defer walk.path.allocator.free(neighbors);

        if (neighbors.len == 0) break;

        // Calculate transition probabilities
        var probabilities = try walk.path.allocator.alloc(f64, neighbors.len);
        defer walk.path.allocator.free(probabilities);

        var total_prob: f64 = 0.0;
        for (neighbors, 0..) |neighbor, i| {
            probabilities[i] = walk.transitionProbability(neighbor, graph);
            total_prob += probabilities[i];
        }

        // Sample next node based on probabilities
        var prng = std.rand.DefaultPrng.init(@intCast(compat_milliTimestamp()));
        const random_value = prng.random().float(f64) * total_prob;

        var cumulative: f64 = 0.0;
        var selected_neighbor: u64 = neighbors[0];
        for (neighbors, probabilities) |neighbor, prob| {
            cumulative += prob;
            if (random_value <= cumulative) {
                selected_neighbor = neighbor;
                break;
            }
        }

        walk.previous_node = current;
        current = selected_neighbor;
        try walk.path.append(current);
        walk.current_node = current;
    }
}

/// Train embeddings using skip-gram model
fn trainSkipGram(manager: *GraphEmbeddingsManager, walk: []const u64, config: EmbeddingConfig) !void {
    for (walk, 0..) |center_node, i| {
        const start = if (i >= config.window_size) i - config.window_size else 0;
        const end = @min(i + config.window_size + 1, walk.len);

        for (start..end) |j| {
            if (i == j) continue;

            const context_node = walk[j];

            // Update embeddings using gradient descent (simplified)
            try updateEmbeddingsPair(manager, center_node, context_node, config);
        }
    }
}

/// Update embeddings for a pair of nodes (simplified gradient descent)
fn updateEmbeddingsPair(manager: *GraphEmbeddingsManager, node1: u64, node2: u64, config: EmbeddingConfig) !void {
    const emb1 = manager.embeddings.getPtr(node1) orelse return;
    const emb2 = manager.embeddings.getPtr(node2) orelse return;

    // Simplified update - in practice would use proper gradient descent
    for (emb1.embedding, emb2.embedding) |*e1, e2| {
        const grad = (e2 - e1.*) * @as(f32, @floatCast(config.learning_rate * 0.1));
        e1.* += grad;
    }

    emb1.updated_at = compat_milliTimestamp();
    emb2.updated_at = compat_milliTimestamp();
}

/// Aggregate neighbor features for GraphSAGE
fn aggregateNeighborFeatures(manager: *GraphEmbeddingsManager, graph: *const geode.graph_common.GraphStore, node_id: u64, config: EmbeddingConfig) !void {
    const neighbors = try graph.getNeighbors(manager.allocator, node_id);
    defer manager.allocator.free(neighbors);

    if (neighbors.len == 0) return;

    const node_embedding = manager.embeddings.getPtr(node_id) orelse return;

    // Sample neighbors if too many
    const sample_size = @min(neighbors.len, config.neighbor_samples);

    // Aggregate neighbor embeddings (mean aggregation)
    const aggregated = try manager.allocator.alloc(f32, config.dimensions);
    defer manager.allocator.free(aggregated);

    // Initialize aggregation array (this mutation justifies var usage)
    for (aggregated) |*val| {
        val.* = 0.0;
    }

    var count: u32 = 0;
    for (neighbors[0..sample_size]) |neighbor_id| {
        if (manager.embeddings.get(neighbor_id)) |neighbor_emb| {
            for (aggregated, neighbor_emb.embedding) |*agg, neighbor_val| {
                agg.* += neighbor_val;
            }
            count += 1;
        }
    }

    if (count > 0) {
        const count_f = @as(f32, @floatFromInt(count));
        for (aggregated) |*value| {
            value.* /= count_f;
        }

        // Update node embedding with aggregated information
        for (node_embedding.embedding, aggregated) |*node_val, agg_val| {
            node_val.* = 0.7 * node_val.* + 0.3 * agg_val; // Weighted combination
        }

        node_embedding.updated_at = compat_milliTimestamp();
    }
}

// Prediction functions

fn predictNode2Vec(manager: *GraphEmbeddingsManager, node_id: u64) ![]f32 {
    const embedding = manager.embeddings.get(node_id) orelse return error.NodeNotFound;

    // Return a copy of the embedding
    const result = try manager.allocator.alloc(f32, embedding.embedding.len);
    std.mem.copyForwards(f32, result, embedding.embedding);
    return result;
}

// GAP-0081: Full GraphSAGE inductive learning for unseen nodes
// CANARY: REQ=REQ-GRAPHSAGE-INDUCTIVE-002; FEATURE="GraphSAGE Inductive Learning"; ASPECT=Prediction; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=ml; UPDATED=2026-01-10
fn predictGraphSAGE(manager: *GraphEmbeddingsManager, node_id: u64) ![]f32 {
    // If the node already has an embedding, return it directly
    if (manager.embeddings.get(node_id)) |existing| {
        const result = try manager.allocator.alloc(f32, existing.embedding.len);
        std.mem.copyForwards(f32, result, existing.embedding);
        return result;
    }

    // For unseen nodes, use inductive learning via neighborhood aggregation
    const graph = manager.trained_graph orelse return error.ModelNotTrained;

    // Get neighbors of the unseen node
    const neighbors = graph.getNeighbors(manager.allocator, node_id) catch |err| {
        // If getNeighbors fails (node truly not in graph), return error
        log.warn("Failed to get neighbors for node {}: {}", .{ node_id, err });
        return error.NodeNotInGraph;
    };
    defer manager.allocator.free(neighbors);

    if (neighbors.len == 0) {
        // Node exists but has no neighbors - initialize random embedding
        log.debug("Node {} has no neighbors, initializing random embedding", .{node_id});
        return initializeRandomEmbedding(manager);
    }

    // Perform multi-layer neighborhood aggregation (GraphSAGE algorithm)
    var current_embedding = try manager.allocator.alloc(f32, manager.config.dimensions);
    errdefer manager.allocator.free(current_embedding);

    // Initialize with mean of neighbor embeddings
    for (current_embedding) |*v| v.* = 0.0;
    var valid_neighbors: u32 = 0;

    // Sample up to neighbor_samples neighbors
    const sample_size = @min(neighbors.len, manager.config.neighbor_samples);

    for (neighbors[0..sample_size]) |neighbor_id| {
        if (manager.embeddings.get(neighbor_id)) |neighbor_emb| {
            for (current_embedding, neighbor_emb.embedding) |*curr, neigh| {
                curr.* += neigh;
            }
            valid_neighbors += 1;
        }
    }

    if (valid_neighbors == 0) {
        // No valid neighbors found - initialize random
        manager.allocator.free(current_embedding);
        return initializeRandomEmbedding(manager);
    }

    // Mean aggregation
    const count_f = @as(f32, @floatFromInt(valid_neighbors));
    for (current_embedding) |*v| {
        v.* /= count_f;
    }

    // Apply learned transformation (if weights available)
    if (manager.aggregation_weights) |weights| {
        const transformed = try applyAggregationWeights(manager, current_embedding, weights[0]);
        manager.allocator.free(current_embedding);
        current_embedding = transformed;
    }

    // Apply ReLU non-linearity
    for (current_embedding) |*v| {
        v.* = @max(0.0, v.*);
    }

    // L2 normalize the embedding
    var norm: f32 = 0.0;
    for (current_embedding) |v| {
        norm += v * v;
    }
    norm = @sqrt(norm);
    if (norm > 0.0) {
        for (current_embedding) |*v| {
            v.* /= norm;
        }
    }

    log.debug("Generated inductive embedding for unseen node {} using {} neighbors", .{ node_id, valid_neighbors });

    return current_embedding;
}

/// Initialize a random embedding for nodes without neighbors
fn initializeRandomEmbedding(manager: *GraphEmbeddingsManager) ![]f32 {
    const embedding = try manager.allocator.alloc(f32, manager.config.dimensions);
    var prng = std.rand.DefaultPrng.init(@intCast(compat_milliTimestamp()));
    const fan_in = @as(f32, @floatFromInt(manager.config.dimensions));
    const xavier_std = @sqrt(2.0 / fan_in);

    for (embedding) |*value| {
        value.* = prng.random().floatNorm(f32) * xavier_std;
    }

    return embedding;
}

/// Apply learned aggregation weights (simplified linear transformation)
fn applyAggregationWeights(manager: *GraphEmbeddingsManager, input: []f32, weights: []f32) ![]f32 {
    const output = try manager.allocator.alloc(f32, manager.config.dimensions);

    // Simple linear transformation: W * [self || aggregated]
    // Since we only have aggregated, apply a projection
    for (output, 0..) |*out, i| {
        var sum: f32 = 0.0;
        for (input, 0..) |in_val, j| {
            const weight_idx = i * manager.config.dimensions + j;
            if (weight_idx < weights.len) {
                sum += in_val * weights[weight_idx];
            } else {
                sum += in_val * 0.1; // Default small weight
            }
        }
        out.* = sum;
    }

    return output;
}

fn predictDeepWalk(manager: *GraphEmbeddingsManager, node_id: u64) ![]f32 {
    return predictNode2Vec(manager, node_id);
}

// Update functions

fn updateNode2Vec(manager: *GraphEmbeddingsManager, node_id: u64, new_embedding: []const f32) !void {
    try manager.updateEmbedding(node_id, new_embedding);
}

fn updateGraphSAGE(manager: *GraphEmbeddingsManager, node_id: u64, new_embedding: []const f32) !void {
    try manager.updateEmbedding(node_id, new_embedding);
}

fn updateDeepWalk(manager: *GraphEmbeddingsManager, node_id: u64, new_embedding: []const f32) !void {
    try manager.updateEmbedding(node_id, new_embedding);
}

// Similarity function

fn calculateSimilarity(manager: *GraphEmbeddingsManager, node1: u64, node2: u64) !f64 {
    const emb1 = manager.embeddings.get(node1) orelse return error.NodeNotFound;
    const emb2 = manager.embeddings.get(node2) orelse return error.NodeNotFound;

    return emb1.cosineSimilarity(&emb2);
}

// Testing and validation functions

test "Graph Embeddings Manager initialization" {
    const allocator = std.testing.allocator;

    const config = EmbeddingConfig{
        .dimensions = 64,
        .epochs = 10,
    };

    var manager = try GraphEmbeddingsManager.init(allocator, config);
    defer manager.deinit();

    try expect(manager.embeddings.count() == 0);
    try expect(manager.algorithm_registry.count() > 0);
    try expect(manager.config.dimensions == 64);
}

test "Embedding vector similarity calculations" {
    const allocator = std.testing.allocator;

    // Create test embeddings
    const emb1_data = try allocator.alloc(f32, 3);
    defer allocator.free(emb1_data);
    emb1_data[0] = 1.0;
    emb1_data[1] = 0.0;
    emb1_data[2] = 0.0;

    const emb2_data = try allocator.alloc(f32, 3);
    defer allocator.free(emb2_data);
    emb2_data[0] = 0.0;
    emb2_data[1] = 1.0;
    emb2_data[2] = 0.0;

    var emb1 = EmbeddingVector{
        .node_id = 1,
        .embedding = emb1_data,
        .algorithm = .node2vec,
        .created_at = 0,
        .updated_at = 0,
    };

    var emb2 = EmbeddingVector{
        .node_id = 2,
        .embedding = emb2_data,
        .algorithm = .node2vec,
        .created_at = 0,
        .updated_at = 0,
    };

    // Test cosine similarity (should be 0 for orthogonal vectors)
    const similarity = emb1.cosineSimilarity(&emb2);
    try expect(@abs(similarity) < 0.001);

    // Test Euclidean distance
    const distance = emb1.euclideanDistance(&emb2);
    try expect(@abs(distance - @sqrt(2.0)) < 0.001);
}

test "Random walk generation" {
    const allocator = std.testing.allocator;

    // Create a simple test graph
    var graph = try geode.graph_common.GraphStore.init(allocator);
    defer graph.deinit();

    // Add nodes and edges for testing
    const n1 = try graph.createNode(&.{});
    const n2 = try graph.createNode(&.{});
    const n3 = try graph.createNode(&.{});
    _ = try graph.createEdge(n1, n2, "CONNECTS");
    _ = try graph.createEdge(n2, n3, "CONNECTS");
    _ = try graph.createEdge(n3, n1, "CONNECTS");

    // Test random walk generation
    var walk = RandomWalk.init(allocator, n1, 1.0, 1.0);
    defer walk.deinit();

    try generateRandomWalk(&walk, &graph, 10);

    try expect(walk.path.items.len <= 10);
    try expect(walk.path.items[0] == n1); // Should start with node 1
}
