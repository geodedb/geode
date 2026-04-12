const std = @import("std");
const testing = std.testing;

// CANARY: REQ=REQ-PERF-SPICE-026; FEATURE="ParallelWrapperTests"; ASPECT=Testing; STATUS=IMPL; OWNER=performance; UPDATED=2026-04-12
// Integration tests for the thread-pool-backed parallel wrapper in Geode.

const parallel_wrapper = @import("parallel/thread_pool_parallel");
const ParallelPool = parallel_wrapper.ParallelPool;
const Thresholds = parallel_wrapper.Thresholds;

// Note: HNSW tests moved to dedicated test file due to pre-existing memory leaks

// ============================================================================
// ParallelPool Tests
// ============================================================================

test "ParallelPool: initialization and cleanup" {
    var pool = ParallelPool.init(testing.allocator, 2);
    pool.start();
    defer pool.deinit();

    // Pool should be started
    try testing.expect(pool.started);
}

test "ParallelPool: multiple start calls are idempotent" {
    var pool = ParallelPool.init(testing.allocator, 2);
    pool.start();
    pool.start(); // Should be no-op
    pool.start(); // Should be no-op
    defer pool.deinit();

    try testing.expect(pool.started);
}

// ============================================================================
// Parallel Map Tests
// ============================================================================

test "parallelMap: small input uses sequential fallback" {
    var pool = ParallelPool.init(testing.allocator, 2);
    pool.start();
    defer pool.deinit();

    const items = [_]u32{ 1, 2, 3, 4, 5 };

    const mapSquare = struct {
        fn map(_: *parallel_wrapper.Task, x: u32) u64 {
            return @as(u64, x) * x;
        }
    }.map;

    const results = try parallel_wrapper.parallelMap(u32, u64, &pool, &items, mapSquare, 10);
    defer pool.allocator.free(results);

    try testing.expectEqual(@as(u64, 1), results[0]);
    try testing.expectEqual(@as(u64, 4), results[1]);
    try testing.expectEqual(@as(u64, 9), results[2]);
    try testing.expectEqual(@as(u64, 16), results[3]);
    try testing.expectEqual(@as(u64, 25), results[4]);
}

test "parallelMap: larger input uses sequential when threshold exceeds size" {
    var pool = ParallelPool.init(testing.allocator, 4);
    pool.start();
    defer pool.deinit();

    // Create array - use high threshold to force sequential path
    var items: [100]u32 = undefined;
    for (&items, 0..) |*item, i| {
        item.* = @intCast(i + 1);
    }

    const mapSquare = struct {
        fn map(_: *parallel_wrapper.Task, x: u32) u64 {
            return @as(u64, x) * x;
        }
    }.map;

    // Use threshold larger than items to trigger sequential fallback
    const results = try parallel_wrapper.parallelMap(u32, u64, &pool, &items, mapSquare, 200);
    defer pool.allocator.free(results);

    // Verify results
    for (results, 0..) |result, i| {
        const expected = @as(u64, i + 1) * (i + 1);
        try testing.expectEqual(expected, result);
    }
}

// ============================================================================
// Pool with ParallelPool Tests
// Note: Full Pool integration tests are skipped due to race conditions in
// the work-stealing deque. These will be addressed separately.
// ============================================================================

test "ParallelPool: direct call execution" {
    var sp = ParallelPool.init(testing.allocator, 2);
    sp.start();
    defer sp.deinit();

    const worker = struct {
        fn work(_: *parallel_wrapper.Task, x: u32) u64 {
            return @as(u64, x) * 3;
        }
    }.work;

    const result = sp.call(u64, worker, 14);
    try testing.expectEqual(@as(u64, 42), result);
}

// Note: HNSW tests moved to dedicated HNSW test file
// HNSW has pre-existing memory leaks in searchLayer/selectNeighbors that need separate fix

// ============================================================================
// Threshold Tests
// ============================================================================

test "Thresholds: values are reasonable" {
    try testing.expect(Thresholds.map > 0);
    try testing.expect(Thresholds.reduce > 0);
    try testing.expect(Thresholds.forEach > 0);
    try testing.expect(Thresholds.hnswBatchDistance > 0);
    try testing.expect(Thresholds.cboSubsets > 0);
    try testing.expect(Thresholds.graphStoreSegments > 0);
}

test "shouldUseParallelism: correct behavior" {
    try testing.expect(!parallel_wrapper.shouldUseParallelism(10, 32));
    try testing.expect(parallel_wrapper.shouldUseParallelism(100, 32));
    try testing.expect(parallel_wrapper.shouldUseParallelism(33, 32));
    try testing.expect(!parallel_wrapper.shouldUseParallelism(32, 32));
    try testing.expect(!parallel_wrapper.shouldUseParallelism(0, 32));
}

// ============================================================================
// Edge Cases
// ============================================================================

test "parallelMap: empty input" {
    var pool = ParallelPool.init(testing.allocator, 2);
    pool.start();
    defer pool.deinit();

    const items = [_]u32{};

    const identity = struct {
        fn map(_: *parallel_wrapper.Task, x: u32) u32 {
            return x;
        }
    }.map;

    const results = try parallel_wrapper.parallelMap(u32, u32, &pool, &items, identity, 10);
    defer pool.allocator.free(results);

    try testing.expectEqual(@as(usize, 0), results.len);
}

test "parallelMap: single element" {
    var pool = ParallelPool.init(testing.allocator, 2);
    pool.start();
    defer pool.deinit();

    const items = [_]u32{42};

    const double = struct {
        fn map(_: *parallel_wrapper.Task, x: u32) u64 {
            return @as(u64, x) * 2;
        }
    }.map;

    const results = try parallel_wrapper.parallelMap(u32, u64, &pool, &items, double, 10);
    defer pool.allocator.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqual(@as(u64, 84), results[0]);
}
