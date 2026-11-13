const std = @import("std");
const parallel = @import("../src/execution/parallel.zig");
const cbo = @import("../src/planner/cbo.zig");
const builtin_algos = @import("../src/graph/builtin_algorithms.zig");

test "multi-threading: thread-pool-backed parallel pool" {
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

    // GAP-0867: the dead CostBasedOptimizer struct was deleted (it referenced
    // nonexistent planner.PlanNode types and never compiled). StatsRegistry
    // is the surviving live CBO surface.
    try registry_smoke(&stats_registry);
}

fn registry_smoke(registry: *cbo.StatsRegistry) !void {
    try registry.injectTableStats("fc_users", 42, 1, 0);
    const st = registry.getTableStats("fc_users") orelse return error.StatsMissing;
    try std.testing.expectEqual(@as(u64, 42), st.row_count);
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
    try std.testing.expect(@sizeOf(cbo.StatsRegistry) > 0);
    try std.testing.expect(@sizeOf(builtin_algos.BuiltinAlgorithms) > 0);
}
