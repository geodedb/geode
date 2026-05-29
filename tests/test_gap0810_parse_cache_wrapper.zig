// CANARY: REQ=REQ-PERF-QPS-0810; FEATURE="ParseCacheWrapper"; ASPECT=PublicSurface; STATUS=TESTED; TEST=tests/test_gap0810_parse_cache_wrapper.zig; OWNER=performance; UPDATED=2026-04-20
//
// GAP-0810 regression test: `geode.parseGqlCached` must expose the existing
// server-side `SharedAstCache` on the public module surface so in-process
// callers (benches, materialized-view refresh, distributed coordinator) can
// amortize parser cost. Parser is ~100x more expensive than the planner per
// `docs/performance/2026-04-20-query-bench/FINAL.md` §6 — any caller that
// executes the same query shape in a loop should route through this wrapper
// instead of `parseGqlOutcome`.
//
// This test exercises the real `SharedAstCache.getOrParse` path (no mocks):
// the first call misses, the second hit increments `hit_count` without
// re-parsing.

const std = @import("std");
const geode = @import("geode");

test "parseGqlCached: second identical call returns cache hit" {
    const a = std.testing.allocator;
    var cache = geode.SharedAstCache.init(a, 16);
    defer cache.deinit();

    const q = "MATCH (p:LT_Person {lt_id: 42}) RETURN p.name";

    // First call: miss.
    switch (try geode.parseGqlCached(&cache, q, .{})) {
        .Err => return error.ParseFailed,
        .Ok => |h1| {
            var h = h1;
            defer h.release();
            const s1 = cache.stats();
            try std.testing.expectEqual(@as(u64, 1), s1.miss_count);
            try std.testing.expectEqual(@as(u64, 0), s1.hit_count);
        },
    }

    // Second call: hit.
    switch (try geode.parseGqlCached(&cache, q, .{})) {
        .Err => return error.ParseFailed,
        .Ok => |h2| {
            var h = h2;
            defer h.release();
            const s2 = cache.stats();
            try std.testing.expectEqual(@as(u64, 1), s2.hit_count);
            try std.testing.expectEqual(@as(u64, 1), s2.miss_count);
        },
    }
}

test "query_ast_cache_shared_singleflight" {
    const worker_count = 32;
    const allocator = std.testing.allocator;
    var cache = geode.SharedAstCache.init(allocator, 64);
    defer cache.deinit();

    const WorkerCtx = struct {
        cache: *geode.SharedAstCache,
        query: []const u8,
        ready: *std.atomic.Value(u32),
        start: *std.atomic.Value(bool),
        successes: *std.atomic.Value(u32),
        failures: *std.atomic.Value(u32),

        fn run(ctx: *@This()) void {
            _ = ctx.ready.fetchAdd(1, .release);
            while (!ctx.start.load(.acquire)) std.atomic.spinLoopHint();

            var handle = switch (geode.parseGqlCached(ctx.cache, ctx.query, .{}) catch {
                _ = ctx.failures.fetchAdd(1, .monotonic);
                return;
            }) {
                .Ok => |h| h,
                .Err => {
                    _ = ctx.failures.fetchAdd(1, .monotonic);
                    return;
                },
            };
            defer handle.release();
            _ = ctx.successes.fetchAdd(1, .release);
        }
    };

    var ready = std.atomic.Value(u32).init(0);
    var start = std.atomic.Value(bool).init(false);
    var successes = std.atomic.Value(u32).init(0);
    var failures = std.atomic.Value(u32).init(0);
    var ctx = WorkerCtx{
        .cache = &cache,
        .query = "RETURN 1 AS c",
        .ready = &ready,
        .start = &start,
        .successes = &successes,
        .failures = &failures,
    };

    var threads: [worker_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, WorkerCtx.run, .{&ctx});
    }
    while (ready.load(.acquire) < worker_count) std.atomic.spinLoopHint();
    start.store(true, .release);
    for (&threads) |thread| thread.join();

    try std.testing.expectEqual(@as(u32, 0), failures.load(.acquire));
    try std.testing.expectEqual(@as(u32, worker_count), successes.load(.acquire));

    const stats = cache.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.miss_count);
    try std.testing.expectEqual(@as(u64, worker_count - 1), stats.hit_count);
}

test "query_ast_cache_concurrent_hits_release_without_serializing" {
    const worker_count = 64;
    const iterations = 128;
    const allocator = std.testing.allocator;
    var cache = geode.SharedAstCache.init(allocator, 64);
    defer cache.deinit();

    const query = "MATCH (n:HCParallel) RETURN count(n) AS c";
    var first = switch (try geode.parseGqlCached(&cache, query, .{})) {
        .Ok => |h| h,
        .Err => return error.ParseFailed,
    };
    first.release();

    const WorkerCtx = struct {
        cache: *geode.SharedAstCache,
        query: []const u8,
        ready: *std.atomic.Value(u32),
        start: *std.atomic.Value(bool),
        successes: *std.atomic.Value(u32),
        failures: *std.atomic.Value(u32),

        fn run(ctx: *@This()) void {
            _ = ctx.ready.fetchAdd(1, .release);
            while (!ctx.start.load(.acquire)) std.atomic.spinLoopHint();

            for (0..iterations) |_| {
                var handle = switch (geode.parseGqlCached(ctx.cache, ctx.query, .{}) catch {
                    _ = ctx.failures.fetchAdd(1, .monotonic);
                    return;
                }) {
                    .Ok => |h| h,
                    .Err => {
                        _ = ctx.failures.fetchAdd(1, .monotonic);
                        return;
                    },
                };
                handle.release();
                _ = ctx.successes.fetchAdd(1, .monotonic);
            }
        }
    };

    var ready = std.atomic.Value(u32).init(0);
    var start = std.atomic.Value(bool).init(false);
    var successes = std.atomic.Value(u32).init(0);
    var failures = std.atomic.Value(u32).init(0);
    var ctx = WorkerCtx{
        .cache = &cache,
        .query = query,
        .ready = &ready,
        .start = &start,
        .successes = &successes,
        .failures = &failures,
    };

    var threads: [worker_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, WorkerCtx.run, .{&ctx});
    }
    while (ready.load(.acquire) < worker_count) std.atomic.spinLoopHint();
    start.store(true, .release);
    for (&threads) |thread| thread.join();

    try std.testing.expectEqual(@as(u32, 0), failures.load(.acquire));
    try std.testing.expectEqual(@as(u32, worker_count * iterations), successes.load(.acquire));

    const stats = cache.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.miss_count);
    try std.testing.expectEqual(@as(u64, worker_count * iterations), stats.hit_count);
}

test "query_ast_cache_unique_misses_do_not_collapse" {
    const worker_count = 32;
    const allocator = std.testing.allocator;
    var cache = geode.SharedAstCache.init(allocator, 128);
    defer cache.deinit();

    const WorkerCtx = struct {
        cache: *geode.SharedAstCache,
        query: []const u8,
        ready: *std.atomic.Value(u32),
        start: *std.atomic.Value(bool),
        successes: *std.atomic.Value(u32),
        failures: *std.atomic.Value(u32),

        fn run(ctx: *@This()) void {
            _ = ctx.ready.fetchAdd(1, .release);
            while (!ctx.start.load(.acquire)) std.atomic.spinLoopHint();

            var handle = switch (geode.parseGqlCached(ctx.cache, ctx.query, .{}) catch {
                _ = ctx.failures.fetchAdd(1, .monotonic);
                return;
            }) {
                .Ok => |h| h,
                .Err => {
                    _ = ctx.failures.fetchAdd(1, .monotonic);
                    return;
                },
            };
            defer handle.release();
            _ = ctx.successes.fetchAdd(1, .release);
        }
    };

    var queries: [worker_count]?[]u8 = .{null} ** worker_count;
    defer for (queries) |query| {
        if (query) |owned| allocator.free(owned);
    };
    var contexts: [worker_count]WorkerCtx = undefined;
    var ready = std.atomic.Value(u32).init(0);
    var start = std.atomic.Value(bool).init(false);
    var successes = std.atomic.Value(u32).init(0);
    var failures = std.atomic.Value(u32).init(0);

    for (&queries, 0..) |*query, i| {
        query.* = try std.fmt.allocPrint(allocator, "RETURN {d} AS c", .{i});
    }
    for (&contexts, 0..) |*ctx, i| {
        ctx.* = .{
            .cache = &cache,
            .query = queries[i].?,
            .ready = &ready,
            .start = &start,
            .successes = &successes,
            .failures = &failures,
        };
    }

    var threads: [worker_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, WorkerCtx.run, .{&contexts[i]});
    }
    while (ready.load(.acquire) < worker_count) std.atomic.spinLoopHint();
    start.store(true, .release);
    for (&threads) |thread| thread.join();

    try std.testing.expectEqual(@as(u32, 0), failures.load(.acquire));
    try std.testing.expectEqual(@as(u32, worker_count), successes.load(.acquire));

    const stats = cache.stats();
    try std.testing.expectEqual(@as(u64, worker_count), stats.miss_count);
    try std.testing.expectEqual(@as(u64, 0), stats.hit_count);
}
