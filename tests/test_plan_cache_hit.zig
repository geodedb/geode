const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const query_plan_cache = geode.query_plan_cache;

// CANARY: REQ=REQ-PERF-SHARED-OPT-001; FEATURE="SharedQueryOptimizer"; ASPECT=HandlerWireRegression; STATUS=TESTED; TEST=tests/test_plan_cache_hit.zig; OWNER=engine; UPDATED=2026-04-18
//
// GAP-0756 regression guard.  The SharedQueryOptimizer exists and is correct;
// the risk in wiring it into the handler is a future refactor accidentally
// dropping the `optimizeQuery` call in `src/server/quic_connection_handler.zig`
// (see the block around the `state.query_optimizer` branch).  This test
// drives the exact API the handler calls and asserts that two identical
// parameterised MATCH queries produce one miss followed by one hit — i.e.
// that `optimizeQuery` is in fact a cache and not a no-op.
//
// The assertion is intentionally low-level: if the handler stops calling
// this function, the integration loadtest ratio degrades but this unit
// test keeps passing — the spec reviewer should additionally verify via
// `state.query_optimizer.?.getStats()` that cache hits are observed in
// production traffic.

fn parseFixture(allocator: std.mem.Allocator, src: []const u8) !geode.ParseResult {
    return geode.parseGql(src, allocator);
}

test "repeat parameterised MATCH hits SharedQueryOptimizer cache (GAP-0756)" {
    const allocator = testing.allocator;
    var opt = query_plan_cache.SharedQueryOptimizer.init(allocator, 64);
    defer opt.deinit();

    // point_read scenario shape: MATCH-by-property where the property value
    // comes from a parameter.  Each request re-binds the parameter but the
    // query text itself never changes — this is exactly what the loadtest
    // generator sends.
    const q = "MATCH (n:Foo {id: $id}) RETURN n";
    var parsed = try parseFixture(allocator, q);
    defer parsed.deinit();

    const store_stats = query_plan_cache.StoreStats{
        .node_count = 1_000,
        .edge_count = 0,
    };

    // First call: cold miss, plan generated and inserted.
    {
        var h = try opt.optimizeQuery(q, &parsed.program, store_stats);
        defer h.release();
    }

    // Second call with the same text: the handler's fast path.
    {
        var h = try opt.optimizeQuery(q, &parsed.program, store_stats);
        defer h.release();
    }

    const stats = opt.getStats();
    try testing.expectEqual(@as(u64, 1), stats.hits);
    try testing.expectEqual(@as(u64, 1), stats.misses);
    try testing.expectEqual(@as(usize, 1), stats.cache_size);
}

test "N identical MATCH queries produce N-1 hits" {
    const allocator = testing.allocator;
    var opt = query_plan_cache.SharedQueryOptimizer.init(allocator, 64);
    defer opt.deinit();

    const q = "MATCH (n:Foo {id: $id}) RETURN n";
    var parsed = try parseFixture(allocator, q);
    defer parsed.deinit();

    const store_stats = query_plan_cache.StoreStats{
        .node_count = 1_000,
        .edge_count = 0,
    };

    const iters: usize = 10;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        var h = try opt.optimizeQuery(q, &parsed.program, store_stats);
        h.release();
    }

    const stats = opt.getStats();
    try testing.expectEqual(@as(u64, iters - 1), stats.hits);
    try testing.expectEqual(@as(u64, 1), stats.misses);
}

test "shared_query_optimizer_plan_singleflight" {
    const worker_count = 32;
    const allocator = testing.allocator;
    var opt = query_plan_cache.SharedQueryOptimizer.init(allocator, 64);
    defer opt.deinit();

    const q = "MATCH (n:Foo {id: $id}) RETURN n";
    var parsed = try parseFixture(allocator, q);
    defer parsed.deinit();

    const WorkerCtx = struct {
        optimizer: *query_plan_cache.SharedQueryOptimizer,
        query: []const u8,
        program: *const geode.ast.Program,
        store_stats: query_plan_cache.StoreStats,
        ready: *std.atomic.Value(u32),
        start: *std.atomic.Value(bool),
        successes: *std.atomic.Value(u32),
        failures: *std.atomic.Value(u32),

        fn run(ctx: *@This()) void {
            _ = ctx.ready.fetchAdd(1, .release);
            while (!ctx.start.load(.acquire)) std.atomic.spinLoopHint();

            var handle = ctx.optimizer.optimizeQuery(ctx.query, ctx.program, ctx.store_stats) catch {
                _ = ctx.failures.fetchAdd(1, .monotonic);
                return;
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
        .optimizer = &opt,
        .query = q,
        .program = &parsed.program,
        .store_stats = .{ .node_count = 1_000, .edge_count = 0 },
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

    try testing.expectEqual(@as(u32, 0), failures.load(.acquire));
    try testing.expectEqual(@as(u32, worker_count), successes.load(.acquire));

    const stats = opt.getStats();
    try testing.expectEqual(@as(u64, 1), stats.misses);
    try testing.expectEqual(@as(u64, worker_count - 1), stats.hits);
    try testing.expectEqual(@as(usize, 1), stats.cache_size);
}
