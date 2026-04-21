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
