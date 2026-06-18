// CANARY: REQ=REQ-PERF-AST-CACHE-BYTES-0900; FEATURE="ASTCacheByteBound"; ASPECT=ByteBoundedEviction; STATUS=TESTED; TEST=tests/test_gap0900_ast_cache_byte_bound.zig; OWNER=performance; UPDATED=2026-06-18
//
// GAP-0900 Layer-3 (Fix 1): the shared AST cache must evict on a TOTAL-BYTES
// budget, not just an entry count. On the batch-ingest workload each cached AST
// is a ~100-MERGE×19-SET program whose parse arena is ~megabytes; a pure
// count cap (2048) therefore admitted ~8 GB of cached ASTs. These tests pin the
// new behavior:
//
//   1. With a small byte budget, inserting several distinct ASTs keeps the
//      cache's total resident bytes at or under the budget (LRU eviction by
//      bytes), even though the entry-count cap is large enough to hold them all.
//   2. The byte bound does not break cache function: a repeated identical query
//      still produces a cache hit.
//   3. `init` (byte bound disabled) preserves the legacy count-only behavior.

const std = @import("std");
const geode = @import("geode");

// Build a distinct, non-trivial query whose parse arena is meaningfully larger
// than a one-liner so a handful of them exceed a small byte budget. Each query
// is unique (different alias index) so they occupy distinct cache slots.
fn buildQuery(allocator: std.mem.Allocator, idx: usize) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "MATCH ");
    // ~40 chained node patterns => a non-trivial AST arena per query.
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        if (i != 0) try buf.appendSlice(allocator, ", ");
        var seg: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&seg, "(n{d}_{d}:Lbl {{k: {d}}})", .{ idx, i, i });
        try buf.appendSlice(allocator, s);
    }
    try buf.appendSlice(allocator, " RETURN n0_0");
    return buf.toOwnedSlice(allocator);
}

test "shared AST cache evicts by total-bytes budget" {
    const a = std.testing.allocator;

    // First, measure the byte footprint of one cached AST under an unbounded
    // (count-only) cache so the test budget is derived from real sizes rather
    // than a guessed constant.
    var probe_cache = geode.SharedAstCache.init(a, 64);
    const sample = try buildQuery(a, 9999);
    defer a.free(sample);
    var one_entry_bytes: usize = 0;
    {
        var h = switch (try geode.parseGqlCached(&probe_cache, sample, .{})) {
            .Ok => |hh| hh,
            .Err => return error.ParseFailed,
        };
        h.release();
        one_entry_bytes = probe_cache.total_bytes;
    }
    probe_cache.deinit();
    try std.testing.expect(one_entry_bytes > 0);

    // Budget that holds ~3 entries. The count cap is deliberately huge so the
    // ONLY thing that can bound the cache is the byte budget.
    const budget = one_entry_bytes * 3;
    var cache = geode.SharedAstCache.initWithByteBudget(a, 100_000, budget);
    defer cache.deinit();

    // Insert 12 distinct ASTs. Without the byte bound all 12 would stay
    // resident (count cap is 100_000). With it, eviction must keep us at or
    // under the budget.
    var qi: usize = 0;
    while (qi < 12) : (qi += 1) {
        const q = try buildQuery(a, qi);
        defer a.free(q);
        var h = switch (try geode.parseGqlCached(&cache, q, .{})) {
            .Ok => |hh| hh,
            .Err => return error.ParseFailed,
        };
        // Release immediately so the entry is evictable (ref_count back to 0).
        h.release();
        // Invariant after each insert: resident bytes never exceed the budget.
        try std.testing.expect(cache.total_bytes <= budget);
    }

    // Fewer than 12 entries remain — eviction actually happened.
    try std.testing.expect(cache.cache.count() < 12);
    try std.testing.expect(cache.cache.count() >= 1);
}

test "byte-bounded cache still serves repeated identical queries from cache" {
    const a = std.testing.allocator;
    // Generous budget — a single repeated small query must hit on the 2nd call.
    var cache = geode.SharedAstCache.initWithByteBudget(a, 64, 64 * 1024 * 1024);
    defer cache.deinit();

    const q = "MATCH (p:Person {id: 7}) RETURN p.name";

    var h1 = switch (try geode.parseGqlCached(&cache, q, .{})) {
        .Ok => |h| h,
        .Err => return error.ParseFailed,
    };
    h1.release();
    {
        const s = cache.stats();
        try std.testing.expectEqual(@as(u64, 1), s.miss_count);
        try std.testing.expectEqual(@as(u64, 0), s.hit_count);
    }

    var h2 = switch (try geode.parseGqlCached(&cache, q, .{})) {
        .Ok => |h| h,
        .Err => return error.ParseFailed,
    };
    h2.release();
    {
        const s = cache.stats();
        try std.testing.expectEqual(@as(u64, 1), s.miss_count);
        try std.testing.expectEqual(@as(u64, 1), s.hit_count);
    }
}

test "init (byte bound disabled) keeps legacy count-only behavior" {
    const a = std.testing.allocator;
    // max_bytes == 0 via init => byte eviction is a no-op; only the count cap
    // bounds the cache. Insert more distinct large ASTs than the byte budget
    // would ever allow and confirm the count cap (not bytes) governs.
    var cache = geode.SharedAstCache.init(a, 8);
    defer cache.deinit();
    try std.testing.expectEqual(@as(usize, 0), cache.max_bytes);

    var qi: usize = 0;
    while (qi < 20) : (qi += 1) {
        const q = try buildQuery(a, qi);
        defer a.free(q);
        var h = switch (try geode.parseGqlCached(&cache, q, .{})) {
            .Ok => |hh| hh,
            .Err => return error.ParseFailed,
        };
        h.release();
    }
    // Count cap of 8 governs; total_bytes is tracked but never triggers
    // eviction.
    try std.testing.expectEqual(@as(usize, 8), cache.cache.count());
    try std.testing.expect(cache.total_bytes > 0);
}
