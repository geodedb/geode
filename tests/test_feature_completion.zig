const std = @import("std");
const parallel = @import("../src/execution/parallel.zig");
const fts = @import("../src/fts/advanced.zig");
const bm25 = @import("../src/fts/bm25.zig");
const cbo = @import("../src/planner/cbo.zig");
const builtin_algos = @import("../src/graph/builtin_algorithms.zig");

test "multi-threading: spice-backed pool" {
    const allocator = std.testing.allocator;

    var pool = try parallel.Pool.init(allocator, 4);
    defer pool.deinit();

    try std.testing.expect(pool.worker_count == 4);
    try std.testing.expect(pool.enabled);

    // Test adaptive chunk estimator
    var estimator = parallel.AdaptiveChunkEstimator.init();
    const chunk_size = estimator.estimateChunkSize(10000, 4);
    try std.testing.expect(chunk_size > 0);
    try std.testing.expect(chunk_size <= 10000);
}

test "advanced FTS: BM25 scoring" {
    const allocator = std.testing.allocator;

    // Test BM25 scoring
    const params = bm25.Params{};
    const score = bm25.score(5, 100, 150, 10, 1000, params);
    try std.testing.expect(score > 0);

    // Test search engine
    var engine = bm25.SearchEngine.init(allocator);
    defer engine.deinit();

    // Test HyperLogLog
    var hll = bm25.IndexStats.HyperLogLog.init();
    hll.add("test1");
    hll.add("test2");
    const cardinality = hll.estimate();
    try std.testing.expect(cardinality > 0);
}

test "advanced FTS: language analyzers" {
    const allocator = std.testing.allocator;

    // Test English analyzer
    var analyzer = try fts.LanguageAnalyzer.init(allocator, .english);
    defer analyzer.deinit();

    const tokens = try analyzer.analyze("The quick brown fox jumps over the lazy dog");
    defer {
        for (tokens) |token| allocator.free(token);
        allocator.free(tokens);
    }

    // Should remove stop words and apply stemming
    try std.testing.expect(tokens.len > 0);
    try std.testing.expect(tokens.len < 9); // Less than word count due to stop words

    // Test fuzzy matching
    const is_match = try fts.fuzzyMatch(allocator, "test", "text", 1);
    try std.testing.expect(is_match);

    // Test Soundex
    const soundex_code = try fts.soundex(allocator, "Smith");
    defer allocator.free(soundex_code);
    try std.testing.expectEqualStrings("S530", soundex_code);
}

test "graph algorithms: comprehensive suite" {
    const allocator = std.testing.allocator;

    var graph = try @import("geode").graph_store.GraphStore.init(allocator);
    defer graph.deinit();

    const n1 = try graph.createNode(&.{"Person"});
    const n2 = try graph.createNode(&.{"Person"});
    const n3 = try graph.createNode(&.{"Person"});

    _ = try graph.createEdge(n1, n2, "KNOWS");
    _ = try graph.createEdge(n2, n3, "KNOWS");

    var algos = builtin_algos.BuiltinAlgorithms.init(allocator, &graph);
    defer algos.deinit();

    var ranks = try algos.pageRank(0.85, 5, 1e-6);
    defer ranks.deinit();
    try std.testing.expectEqual(@as(usize, 3), ranks.count());
}

test "CBO: advanced features" {
    const allocator = std.testing.allocator;

    var stats_registry = cbo.StatsRegistry.init(allocator);
    defer stats_registry.deinit();

    // Test frequency histogram
    var freq_hist = cbo.StatsRegistry.FrequencyHistogram.init(allocator);
    defer freq_hist.deinit();

    try freq_hist.addValue("value1");
    try freq_hist.addValue("value1");
    try freq_hist.addValue("value2");

    const selectivity = freq_hist.estimateSelectivity("value1");
    try std.testing.expect(selectivity > 0.6 and selectivity < 0.7);

    // Test HyperLogLog
    var hll = cbo.StatsRegistry.HyperLogLog.init();
    hll.add("item1");
    hll.add("item2");
    hll.add("item3");

    const estimate = hll.estimate();
    try std.testing.expect(estimate > 0);

    // Test CBO initialization
    var optimizer = try cbo.CostBasedOptimizer.init(allocator);
    defer optimizer.deinit();

    try std.testing.expect(optimizer.enabled);
    try std.testing.expect(optimizer.stats_registry != null);
    try std.testing.expect(optimizer.cardinality_estimator != null);
    try std.testing.expect(optimizer.cost_model != null);
}

test "parallel pipeline execution" {
    const allocator = std.testing.allocator;

    var pool = try parallel.Pool.init(allocator, 2);
    defer pool.deinit();

    const stages = [_]parallel.ParallelPipeline.PipelineStage{
        .{
            .name = "stage1",
            .parallelism = 2,
            .process = struct {
                fn process(item: *anyopaque, ctx: *anyopaque) !void {
                    _ = item;
                    _ = ctx;
                }
            }.process,
            .ctx = null,
        },
    };

    var pipeline = parallel.ParallelPipeline.init(allocator, &pool, &stages);

    const input = [_]*anyopaque{};
    try pipeline.execute(&input);
}

test "integration: all features compile and link" {
    // This test verifies that all enhanced features compile together
    // without conflicts or missing dependencies

    try std.testing.expect(@sizeOf(parallel.Pool) > 0);
    try std.testing.expect(@sizeOf(fts.AdvancedSearch) > 0);
    try std.testing.expect(@sizeOf(bm25.BM25F) > 0);
    try std.testing.expect(@sizeOf(cbo.CardinalityEstimator) > 0);
    try std.testing.expect(@sizeOf(builtin_algos.BuiltinAlgorithms) > 0);
}
