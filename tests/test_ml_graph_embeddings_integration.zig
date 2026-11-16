// GAP-0879: ML embeddings truth.
//
// This file replaces the previous "integration" tests which (a) targeted an
// API that never existed (the file was not wired into any build step and did
// not compile), (b) SIMULATED training loss with fabricated decreasing
// numbers (`current_loss = 1.0 / (epoch + 1)`), and (c) shipped a helper
// random-walk that silently ignored the Node2Vec p/q bias parameters.
//
// The tests below exercise the REAL exported module
// (src/ml/graph_embeddings.zig) against a REAL GraphStore:
//
//   1. Node2Vec p (return) bias: on K4, walks with small p must return to the
//      previous node far more often than walks with large p.
//   2. Node2Vec q (in-out) bias: on a 5-cycle, walks with small q must step to
//      distance-2 nodes (away from the previous node) far more often than
//      walks with large q.
//   3. Real training loss: trainEmbeddings(.node2vec) on two triangles must
//      produce a finite, non-negative per-epoch loss that DECREASES from the
//      first epoch to the last — computed from the actual embeddings, never
//      simulated.
//   4. Deterministic seeding: identical config.seed must reproduce identical
//      embeddings.
//
// All statistical assertions use deterministic seeds and margins that are
// several multiples of the expected separation (no flakiness): with the
// chosen parameters the expected return fraction is ~0.83 vs ~0.05, and the
// expected outward fraction is ~0.91 vs ~0.09.
//
// CANARY: REQ=REQ-ML-EMBEDDINGS-002; FEATURE="Node2Vec Algorithm"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_ml_graph_embeddings_integration.zig; OWNER=ml; UPDATED=2026-06-11

const std = @import("std");
const testing = std.testing;

const geode = @import("geode");
const graph_store = geode.graph_store;
const ml = geode.ml.graph_embeddings;

/// Add an undirected edge (two directed edges) to the store.
fn addUndirectedEdge(store: *graph_store.GraphStore, a: u64, b: u64) !void {
    _ = try store.createEdge(a, b, "LINK");
    _ = try store.createEdge(b, a, "LINK");
}

const StepStats = struct {
    /// steps where next == previous (distance 0 from previous)
    returns: u64 = 0,
    /// steps where next is adjacent to previous (distance 1)
    dist1: u64 = 0,
    /// steps where next is neither previous nor adjacent to it (distance 2)
    dist2: u64 = 0,
    total: u64 = 0,

    fn returnFraction(self: StepStats) f64 {
        return @as(f64, @floatFromInt(self.returns)) / @as(f64, @floatFromInt(self.total));
    }

    fn dist2Fraction(self: StepStats) f64 {
        return @as(f64, @floatFromInt(self.dist2)) / @as(f64, @floatFromInt(self.total));
    }
};

/// Run `num_walks` biased walks of `walk_length` from each node in `starts`
/// and classify every transition (prev, cur) -> next by its Node2Vec
/// distance-from-previous category.
fn collectWalkStats(
    allocator: std.mem.Allocator,
    store: *const graph_store.GraphStore,
    starts: []const u64,
    num_walks: usize,
    walk_length: u32,
    p: f64,
    q: f64,
    rng: std.Random,
) !StepStats {
    var stats = StepStats{};

    for (starts) |start| {
        for (0..num_walks) |_| {
            var walk = try ml.RandomWalk.init(allocator, start, p, q);
            defer walk.deinit();

            try ml.generateRandomWalk(&walk, store, walk_length, rng);

            const path = walk.path.items;
            var k: usize = 2;
            while (k < path.len) : (k += 1) {
                const prev = path[k - 2];
                const next = path[k];
                stats.total += 1;
                if (next == prev) {
                    stats.returns += 1;
                } else if (try store.hasEdge(prev, next)) {
                    stats.dist1 += 1;
                } else {
                    stats.dist2 += 1;
                }
            }
        }
    }

    try testing.expect(stats.total > 0);
    return stats;
}

test "GAP-0879 (1): small p makes walks return-heavy, large p suppresses returns (K4)" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    try store.createGraph("default");

    // K4: every pair of nodes connected. From any (prev, cur) the candidate
    // set is {prev (weight 1/p), two nodes adjacent to prev (weight 1 each)};
    // q never applies, isolating the return parameter.
    const labels = [_][]const u8{"N"};
    var ids: [4]u64 = undefined;
    for (&ids) |*id| id.* = try store.createNode(&labels);
    for (0..4) |i| {
        for (i + 1..4) |j| {
            try addUndirectedEdge(&store, ids[i], ids[j]);
        }
    }

    const num_walks = 200;
    const walk_length: u32 = 20;

    // p = 0.1 (return weight 10 vs 1+1): expected return fraction ~ 10/12 = 0.83
    var prng_small = std.Random.DefaultPrng.init(42);
    const small_p = try collectWalkStats(allocator, &store, &ids, num_walks, walk_length, 0.1, 1.0, prng_small.random());

    // p = 10 (return weight 0.1 vs 1+1): expected return fraction ~ 0.1/2.1 = 0.048
    var prng_large = std.Random.DefaultPrng.init(42);
    const large_p = try collectWalkStats(allocator, &store, &ids, num_walks, walk_length, 10.0, 1.0, prng_large.random());

    const small_frac = small_p.returnFraction();
    const large_frac = large_p.returnFraction();

    // Expected ~0.83 vs ~0.05; assert with wide, non-flaky margins.
    try testing.expect(small_frac > 0.6);
    try testing.expect(large_frac < 0.15);
    try testing.expect(small_frac > 4.0 * large_frac);

    // K4 has no distance-2 candidates: the classifier must agree.
    try testing.expectEqual(@as(u64, 0), small_p.dist2);
    try testing.expectEqual(@as(u64, 0), large_p.dist2);
}

test "GAP-0879 (2): small q pushes walks outward to distance-2 nodes (5-cycle)" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    try store.createGraph("default");

    // 5-cycle (no triangles): from (prev, cur) the candidates are exactly
    // {prev (weight 1/p)} and {the next node around the ring, which is at
    // distance 2 from prev (weight 1/q)} — isolating the in-out parameter.
    const labels = [_][]const u8{"N"};
    var ids: [5]u64 = undefined;
    for (&ids) |*id| id.* = try store.createNode(&labels);
    for (0..5) |i| {
        try addUndirectedEdge(&store, ids[i], ids[(i + 1) % 5]);
    }

    const num_walks = 200;
    const walk_length: u32 = 20;

    // q = 0.1 (outward weight 10 vs return 1): expected dist-2 fraction ~ 10/11 = 0.91
    var prng_small = std.Random.DefaultPrng.init(7);
    const small_q = try collectWalkStats(allocator, &store, &ids, num_walks, walk_length, 1.0, 0.1, prng_small.random());

    // q = 10 (outward weight 0.1 vs return 1): expected dist-2 fraction ~ 0.1/1.1 = 0.09
    var prng_large = std.Random.DefaultPrng.init(7);
    const large_q = try collectWalkStats(allocator, &store, &ids, num_walks, walk_length, 1.0, 10.0, prng_large.random());

    const small_frac = small_q.dist2Fraction();
    const large_frac = large_q.dist2Fraction();

    // Expected ~0.91 vs ~0.09; assert with wide, non-flaky margins.
    try testing.expect(small_frac > 0.7);
    try testing.expect(large_frac < 0.3);
    try testing.expect(small_frac > 2.0 * large_frac);
}

/// Build the tiny deterministic training graph: two triangles (1-2-3, 4-5-6).
fn buildTwoTriangles(allocator: std.mem.Allocator) !graph_store.GraphStore {
    var store = try graph_store.GraphStore.init(allocator);
    errdefer store.deinit();
    try store.createGraph("default");

    const labels = [_][]const u8{"N"};
    var ids: [6]u64 = undefined;
    for (&ids) |*id| id.* = try store.createNode(&labels);

    // Triangle A: 0-1-2, Triangle B: 3-4-5
    try addUndirectedEdge(&store, ids[0], ids[1]);
    try addUndirectedEdge(&store, ids[1], ids[2]);
    try addUndirectedEdge(&store, ids[2], ids[0]);
    try addUndirectedEdge(&store, ids[3], ids[4]);
    try addUndirectedEdge(&store, ids[4], ids[5]);
    try addUndirectedEdge(&store, ids[5], ids[3]);

    return store;
}

const training_config = ml.EmbeddingConfig{
    .dimensions = 16,
    .learning_rate = 0.05,
    .epochs = 5,
    .walk_length = 8,
    .num_walks = 4,
    .window_size = 2,
    .p = 1.0,
    .q = 1.0,
    .seed = 1234,
};

test "GAP-0879 (3): real Node2Vec training loss is finite and decreases over epochs" {
    const allocator = testing.allocator;

    var store = try buildTwoTriangles(allocator);
    defer store.deinit();

    var manager = try ml.GraphEmbeddingsManager.init(allocator, training_config);
    defer manager.deinit();

    // REAL training epochs on the real graph — Admin role satisfies the
    // cross-tenant training authorization whether or not auth is enabled.
    try manager.trainEmbeddings(&store, .node2vec, null, .Admin);

    const ctx = manager.training_context orelse return error.TrainingContextMissing;

    // Loss is the real mean pre-update squared distance over skip-gram pairs.
    try testing.expect(std.math.isFinite(ctx.initial_loss));
    try testing.expect(std.math.isFinite(ctx.loss));
    try testing.expect(ctx.initial_loss > 0.0);
    try testing.expect(ctx.loss >= 0.0);

    // The pull-together update contracts co-occurring pair distances, so the
    // final epoch loss must be strictly below the first epoch loss.
    try testing.expect(ctx.loss < ctx.initial_loss);

    // Every node got a real embedding of the configured dimensionality.
    const nodes = try store.getAllNodesForTenant(allocator, null);
    defer allocator.free(nodes);
    try testing.expectEqual(@as(usize, 6), nodes.len);
    for (nodes) |node_id| {
        const emb = manager.getEmbedding(node_id) orelse return error.MissingEmbedding;
        try testing.expectEqual(@as(usize, training_config.dimensions), emb.embedding.len);
        for (emb.embedding) |v| {
            try testing.expect(std.math.isFinite(v));
        }
    }
}

test "GAP-0879 (4): identical seed reproduces identical embeddings" {
    const allocator = testing.allocator;

    var store = try buildTwoTriangles(allocator);
    defer store.deinit();

    var manager_a = try ml.GraphEmbeddingsManager.init(allocator, training_config);
    defer manager_a.deinit();
    try manager_a.trainEmbeddings(&store, .node2vec, null, .Admin);

    var manager_b = try ml.GraphEmbeddingsManager.init(allocator, training_config);
    defer manager_b.deinit();
    try manager_b.trainEmbeddings(&store, .node2vec, null, .Admin);

    const nodes = try store.getAllNodesForTenant(allocator, null);
    defer allocator.free(nodes);

    for (nodes) |node_id| {
        const emb_a = manager_a.getEmbedding(node_id) orelse return error.MissingEmbedding;
        const emb_b = manager_b.getEmbedding(node_id) orelse return error.MissingEmbedding;
        try testing.expectEqualSlices(f32, emb_a.embedding, emb_b.embedding);
    }

    // Same training run also records the same loss trajectory endpoints.
    const ctx_a = manager_a.training_context.?;
    const ctx_b = manager_b.training_context.?;
    try testing.expectEqual(ctx_a.initial_loss, ctx_b.initial_loss);
    try testing.expectEqual(ctx_a.loss, ctx_b.loss);
}
