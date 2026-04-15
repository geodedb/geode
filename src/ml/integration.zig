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

pub const EmbeddingDimension = u32;
pub const Embedding = []f32;

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
};

pub const GraphSAGEParams = struct {
    dimensions: EmbeddingDimension = 256,
    aggregator: enum { mean, max, lstm, pool } = .mean,
    layers: u32 = 2,
    batch_size: u32 = 512,
    learning_rate: f32 = 0.001,
    epochs: u32 = 10,
};

pub const LinkPredictionParams = struct {
    method: enum { hadamard, l1, l2, average, cosine } = .hadamard,
    threshold: f32 = 0.5,
    negative_sampling_ratio: f32 = 1.0,
};

pub const NodeClassificationParams = struct {
    algorithm: enum { logistic_regression, random_forest, neural_network } = .logistic_regression,
    train_split: f32 = 0.8,
    validation_split: f32 = 0.1,
    test_split: f32 = 0.1,
    epochs: u32 = 100,
};

pub const CommunityDetectionParams = struct {
    algorithm: enum { louvain, leiden, label_propagation, infomap } = .louvain,
    resolution: f32 = 1.0,
    iterations: u32 = 100,
};

pub const MLModel = struct {
    allocator: Allocator,
    algorithm: MLAlgorithm,
    embeddings: std.AutoHashMap(u64, Embedding), // node_id -> embedding
    metadata: ModelMetadata,

    const Self = @This();

    pub fn init(allocator: Allocator, algorithm: MLAlgorithm) !Self {
        return Self{
            .allocator = allocator,
            .algorithm = algorithm,
            .embeddings = std.AutoHashMap(u64, Embedding).init(allocator),
            .metadata = ModelMetadata{},
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.embeddings.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.embeddings.deinit();
    }

    pub fn getEmbedding(self: *Self, node_id: u64) ?Embedding {
        return self.embeddings.get(node_id);
    }

    pub fn setEmbedding(self: *Self, node_id: u64, embedding: Embedding) !void {
        const owned = try self.allocator.dupe(f32, embedding);
        try self.embeddings.put(node_id, owned);
    }
};

pub const ModelMetadata = struct {
    created_at: i64 = 0,
    updated_at: i64 = 0,
    training_time_ms: u64 = 0,
    parameters: []u8 = &[_]u8{},
};

pub const MLEngine = struct {
    allocator: Allocator,
    models: std.StringHashMap(*MLModel),
    active_model: ?*MLModel,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        return Self{
            .allocator = allocator,
            .models = std.StringHashMap(*MLModel).init(allocator),
            .active_model = null,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.models.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.models.deinit();
    }

    pub fn node2vec(self: *Self, params: Node2VecParams) !*MLModel {
        const model = try self.allocator.create(MLModel);
        model.* = try MLModel.init(self.allocator, .node2vec);

        // Implementation of Node2Vec algorithm
        try self.computeNode2Vec(model, params);

        const model_name = try std.fmt.allocPrint(self.allocator, "node2vec_{d}", .{compat_milliTimestamp()});
        try self.models.put(model_name, model);
        self.active_model = model;

        return model;
    }

    fn computeNode2Vec(self: *Self, model: *MLModel, params: Node2VecParams) !void {

        // Simplified Node2Vec implementation
        // In practice, this would:
        // 1. Generate random walks
        // 2. Train Skip-gram model
        // 3. Generate embeddings

        // For demonstration, generate random embeddings
        var prng = std.Random.DefaultPrng.init(@intCast(compat_milliTimestamp()));
        const random = prng.random();

        // Generate embeddings for sample nodes
        var node_id: u64 = 1;
        while (node_id <= 100) : (node_id += 1) {
            const embedding = try self.allocator.alloc(f32, params.dimensions);
            for (embedding) |*val| {
                val.* = random.float(f32) * 2.0 - 1.0; // [-1, 1]
            }
            try model.setEmbedding(node_id, embedding);
            self.allocator.free(embedding);
        }

        model.metadata.training_time_ms = 100; // Mock training time
        model.metadata.created_at = compat_milliTimestamp();
    }

    pub fn linkPrediction(self: *Self, source: u64, target: u64, params: LinkPredictionParams) !f32 {
        const model = self.active_model orelse return error.NoActiveModel;

        const source_emb = model.getEmbedding(source) orelse return error.NodeNotFound;
        const target_emb = model.getEmbedding(target) orelse return error.NodeNotFound;

        // Compute similarity based on method
        const score = switch (params.method) {
            .hadamard => self.hadamardProduct(source_emb, target_emb),
            .cosine => self.cosineSimilarity(source_emb, target_emb),
            .l1 => self.l1Distance(source_emb, target_emb),
            .l2 => self.l2Distance(source_emb, target_emb),
            .average => self.averageEmbeddings(source_emb, target_emb),
        };

        return score;
    }

    fn hadamardProduct(self: *Self, a: Embedding, b: Embedding) f32 {
        _ = self;
        var sum: f32 = 0;
        for (a, b) |val_a, val_b| {
            sum += val_a * val_b;
        }
        return sum / @as(f32, @floatFromInt(a.len));
    }

    fn cosineSimilarity(self: *Self, a: Embedding, b: Embedding) f32 {
        _ = self;
        var dot_product: f32 = 0;
        var norm_a: f32 = 0;
        var norm_b: f32 = 0;

        for (a, b) |val_a, val_b| {
            dot_product += val_a * val_b;
            norm_a += val_a * val_a;
            norm_b += val_b * val_b;
        }

        return dot_product / (@sqrt(norm_a) * @sqrt(norm_b));
    }

    fn l1Distance(self: *Self, a: Embedding, b: Embedding) f32 {
        _ = self;
        var sum: f32 = 0;
        for (a, b) |val_a, val_b| {
            sum += @abs(val_a - val_b);
        }
        return 1.0 / (1.0 + sum);
    }

    fn l2Distance(self: *Self, a: Embedding, b: Embedding) f32 {
        _ = self;
        var sum: f32 = 0;
        for (a, b) |val_a, val_b| {
            const diff = val_a - val_b;
            sum += diff * diff;
        }
        return 1.0 / (1.0 + @sqrt(sum));
    }

    fn averageEmbeddings(self: *Self, a: Embedding, b: Embedding) f32 {
        _ = self;
        var sum: f32 = 0;
        for (a, b) |val_a, val_b| {
            sum += (val_a + val_b) / 2.0;
        }
        return sum / @as(f32, @floatFromInt(a.len));
    }

    pub fn nodeClassification(self: *Self, node_id: u64, params: NodeClassificationParams) ![]const u8 {
        _ = params;
        const model = self.active_model orelse return error.NoActiveModel;

        const embedding = model.getEmbedding(node_id) orelse return error.NodeNotFound;

        // Simple classification based on embedding values
        // In practice, this would use a trained classifier
        var sum: f32 = 0;
        for (embedding) |val| {
            sum += val;
        }

        if (sum > 0) {
            return "class_a";
        } else {
            return "class_b";
        }
    }

    pub fn communityDetection(self: *Self, params: CommunityDetectionParams) !std.AutoHashMap(u64, u32) {
        _ = params;
        const model = self.active_model orelse return error.NoActiveModel;

        var communities = std.AutoHashMap(u64, u32).init(self.allocator);

        // Simple community assignment based on embedding clustering
        // In practice, would use Louvain or similar algorithm
        var it = model.embeddings.iterator();
        while (it.next()) |entry| {
            const node_id = entry.key_ptr.*;
            const embedding = entry.value_ptr.*;

            // Assign community based on first dimension sign
            const community: u32 = if (embedding[0] > 0) 0 else 1;
            try communities.put(node_id, community);
        }

        return communities;
    }
};

// GDS (Graph Data Science) procedures
pub const GDSProcedures = struct {
    engine: *MLEngine,

    const Self = @This();

    pub fn init(engine: *MLEngine) Self {
        return Self{ .engine = engine };
    }

    // CALL gds.node2vec.stream()
    pub fn node2vecStream(self: *Self, params: Node2VecParams) !StreamResult {
        const model = try self.engine.node2vec(params);

        var results = std.ArrayList(Node2VecResult){};
        var it = model.embeddings.iterator();
        while (it.next()) |entry| {
            try results.append(.{
                .nodeId = entry.key_ptr.*,
                .embedding = entry.value_ptr.*,
            });
        }

        return StreamResult{
            .columns = &[_][]const u8{ "nodeId", "embedding" },
            .rows = results.items,
        };
    }

    // CALL gds.linkPrediction.mutate()
    pub fn linkPredictionMutate(self: *Self, source: u64, target: u64) !f32 {
        return self.engine.linkPrediction(source, target, .{});
    }

    // CALL gds.louvain.stream()
    pub fn louvainStream(self: *Self) !StreamResult {
        const communities = try self.engine.communityDetection(.{});
        defer communities.deinit();

        var results = std.ArrayList(CommunityResult){};
        var it = communities.iterator();
        while (it.next()) |entry| {
            try results.append(.{
                .nodeId = entry.key_ptr.*,
                .communityId = entry.value_ptr.*,
            });
        }

        return StreamResult{
            .columns = &[_][]const u8{ "nodeId", "communityId" },
            .rows = results.items,
        };
    }
};

pub const StreamResult = struct {
    columns: []const []const u8,
    rows: []const []const u8,
};

pub const Node2VecResult = struct {
    nodeId: u64,
    embedding: Embedding,
};

pub const CommunityResult = struct {
    nodeId: u64,
    communityId: u32,
};

test "node2vec embeddings" {
    const allocator = std.testing.allocator;

    var engine = try MLEngine.init(allocator);
    defer engine.deinit();

    const params = Node2VecParams{
        .dimensions = 64,
        .walk_length = 10,
        .num_walks = 5,
    };

    const model = try engine.node2vec(params);

    // Check embeddings were generated
    const embedding = model.getEmbedding(1);
    try std.testing.expect(embedding != null);
    try std.testing.expect(embedding.?.len == 64);
}

test "link prediction" {
    const allocator = std.testing.allocator;

    var engine = try MLEngine.init(allocator);
    defer engine.deinit();

    // Generate embeddings
    _ = try engine.node2vec(.{ .dimensions = 32 });

    // Predict link
    const score = try engine.linkPrediction(1, 2, .{ .method = .cosine });
    try std.testing.expect(score >= -1.0 and score <= 1.0);
}

test "community detection" {
    const allocator = std.testing.allocator;

    var engine = try MLEngine.init(allocator);
    defer engine.deinit();

    // Generate embeddings
    _ = try engine.node2vec(.{ .dimensions = 32 });

    // Detect communities
    var communities = try engine.communityDetection(.{ .algorithm = .louvain });
    defer communities.deinit();

    try std.testing.expect(communities.count() > 0);
}
