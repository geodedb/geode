const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const query_plan_cache = geode.query_plan_cache;

// CANARY: REQ=REQ-PERF-SHARED-OPT-001; FEATURE="SharedQueryOptimizer"; ASPECT=UnitTest; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
// Issue #460: Shared cross-connection optimizer unit tests

/// Helper: parse a query to get a Program for use with optimizeQuery
fn parseQuery(allocator: std.mem.Allocator, src: []const u8) !geode.ParseResult {
    return geode.parseGql(src, allocator);
}

test "SharedQueryOptimizer: init and deinit" {
    const allocator = testing.allocator;
    var opt = query_plan_cache.SharedQueryOptimizer.init(allocator, 64);
    defer opt.deinit();

    const stats = opt.getStats();
    try testing.expectEqual(@as(u64, 0), stats.hits);
    try testing.expectEqual(@as(u64, 0), stats.misses);
    try testing.expectEqual(@as(usize, 0), stats.cache_size);
}

test "SharedQueryOptimizer: cache miss then hit" {
    const allocator = testing.allocator;
    var opt = query_plan_cache.SharedQueryOptimizer.init(allocator, 64);
    defer opt.deinit();

    var parsed = try parseQuery(allocator, "MATCH (n) RETURN n");
    defer parsed.deinit();

    const store_stats = query_plan_cache.StoreStats{ .node_count = 100, .edge_count = 50 };

    // First call — cache miss
    var handle1 = try opt.optimizeQuery("MATCH (n) RETURN n", &parsed.program, store_stats);
    defer handle1.release();

    const stats1 = opt.getStats();
    try testing.expectEqual(@as(u64, 0), stats1.hits);
    try testing.expectEqual(@as(u64, 1), stats1.misses);

    // Second call with same query — cache hit
    var handle2 = try opt.optimizeQuery("MATCH (n) RETURN n", &parsed.program, store_stats);
    defer handle2.release();

    const stats2 = opt.getStats();
    try testing.expectEqual(@as(u64, 1), stats2.hits);
    try testing.expectEqual(@as(u64, 1), stats2.misses);
}

test "SharedQueryOptimizer: different queries get different entries" {
    const allocator = testing.allocator;
    var opt = query_plan_cache.SharedQueryOptimizer.init(allocator, 64);
    defer opt.deinit();

    var p1 = try parseQuery(allocator, "MATCH (a) RETURN a");
    defer p1.deinit();
    var p2 = try parseQuery(allocator, "MATCH (b) RETURN b");
    defer p2.deinit();

    const store_stats = query_plan_cache.StoreStats{ .node_count = 100, .edge_count = 50 };

    var h1 = try opt.optimizeQuery("MATCH (a) RETURN a", &p1.program, store_stats);
    defer h1.release();
    var h2 = try opt.optimizeQuery("MATCH (b) RETURN b", &p2.program, store_stats);
    defer h2.release();

    const stats = opt.getStats();
    try testing.expectEqual(@as(usize, 2), stats.cache_size);
    try testing.expectEqual(@as(u64, 0), stats.hits);
    try testing.expectEqual(@as(u64, 2), stats.misses);
}

test "SharedQueryOptimizer: schema epoch invalidation" {
    const allocator = testing.allocator;
    var opt = query_plan_cache.SharedQueryOptimizer.init(allocator, 64);
    defer opt.deinit();

    var parsed = try parseQuery(allocator, "MATCH (n:Person) RETURN n");
    defer parsed.deinit();

    const store_stats = query_plan_cache.StoreStats{ .node_count = 100, .edge_count = 50 };

    // Cache a query
    {
        var h = try opt.optimizeQuery("MATCH (n:Person) RETURN n", &parsed.program, store_stats);
        h.release();
    }

    // Bump schema epoch (simulating DDL)
    opt.bumpSchemaEpoch();

    // Same query should be a miss now (stale epoch)
    {
        var h = try opt.optimizeQuery("MATCH (n:Person) RETURN n", &parsed.program, store_stats);
        h.release();
    }

    const stats = opt.getStats();
    // Both calls should be misses (second due to stale epoch)
    try testing.expectEqual(@as(u64, 0), stats.hits);
    try testing.expectEqual(@as(u64, 2), stats.misses);
}

test "SharedQueryOptimizer: invalidateAll clears cache" {
    const allocator = testing.allocator;
    var opt = query_plan_cache.SharedQueryOptimizer.init(allocator, 64);
    defer opt.deinit();

    var p1 = try parseQuery(allocator, "RETURN 1");
    defer p1.deinit();
    var p2 = try parseQuery(allocator, "RETURN 2");
    defer p2.deinit();

    const store_stats = query_plan_cache.StoreStats{ .node_count = 100, .edge_count = 50 };

    {
        var h = try opt.optimizeQuery("RETURN 1", &p1.program, store_stats);
        h.release();
    }
    {
        var h = try opt.optimizeQuery("RETURN 2", &p2.program, store_stats);
        h.release();
    }

    try testing.expectEqual(@as(usize, 2), opt.getStats().cache_size);

    opt.invalidateAll();

    try testing.expectEqual(@as(usize, 0), opt.getStats().cache_size);
}

test "SharedQueryOptimizer: LRU eviction when max_size exceeded" {
    const allocator = testing.allocator;
    var opt = query_plan_cache.SharedQueryOptimizer.init(allocator, 2);
    defer opt.deinit();

    var p1 = try parseQuery(allocator, "RETURN 1");
    defer p1.deinit();
    var p2 = try parseQuery(allocator, "RETURN 2");
    defer p2.deinit();
    var p3 = try parseQuery(allocator, "RETURN 3");
    defer p3.deinit();

    const store_stats = query_plan_cache.StoreStats{ .node_count = 100, .edge_count = 50 };

    {
        var h = try opt.optimizeQuery("RETURN 1", &p1.program, store_stats);
        h.release();
    }
    {
        var h = try opt.optimizeQuery("RETURN 2", &p2.program, store_stats);
        h.release();
    }

    try testing.expectEqual(@as(usize, 2), opt.getStats().cache_size);

    {
        var h = try opt.optimizeQuery("RETURN 3", &p3.program, store_stats);
        h.release();
    }

    try testing.expect(opt.getStats().cache_size <= 2);
}

test "SharedQueryOptimizer: SharedPlanHandle toHints" {
    const allocator = testing.allocator;
    var opt = query_plan_cache.SharedQueryOptimizer.init(allocator, 64);
    defer opt.deinit();

    var parsed = try parseQuery(allocator, "MATCH (n) RETURN n");
    defer parsed.deinit();

    const store_stats = query_plan_cache.StoreStats{ .node_count = 100, .edge_count = 50 };

    var handle = try opt.optimizeQuery("MATCH (n) RETURN n", &parsed.program, store_stats);
    defer handle.release();

    const hints = handle.toHints();
    try testing.expect(hints.estimated_rows > 0);
    try testing.expectEqual(query_plan_cache.CompiledPlan.ScanStrategy.full_scan, hints.scan_strategy);
}

test "SharedQueryOptimizer: hashQueryText consistency" {
    const h1 = query_plan_cache.hashQueryText("MATCH (n) RETURN n");
    const h2 = query_plan_cache.hashQueryText("MATCH (n) RETURN n");
    const h3 = query_plan_cache.hashQueryText("MATCH (m) RETURN m");

    try testing.expectEqual(h1, h2);
    try testing.expect(h1 != h3);
}
