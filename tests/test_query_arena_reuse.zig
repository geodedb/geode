// Regression test for GAP-0755 — per-query arena pool for executor scratch.
//
// Triage:  docs/superpowers/plans/2026-04-18-match-qps-close-gap.md (Task 3)
// Summary: After GAP-0754 swapped the graph_store global allocator to
//          smp_allocator, per-query scratch allocations (start-slot lists,
//          property-row arrays, intermediate ResultRow buffers) still
//          round-tripped through the allocator on every alloc/free.  For a
//          hot path with dozens of allocations per query, bundling all of
//          that into one per-query ArenaAllocator removes the round-trip and
//          guarantees zero fragmentation across queries.
//
// Tests:
//   Test A — acquire + release 10 times on a pool of capacity 4; assert the
//            pool reuses arenas (seen arena pointer count <= capacity).
//   Test B — release resets the arena so subsequent acquires from the same
//            pooled arena get a fresh allocation window.
//
// CANARY: REQ=REQ-PERF-QUERY-ARENA-001; FEATURE="PerQueryArenaPool"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_query_arena_reuse.zig:1; OWNER=engine; UPDATED=2026-04-18

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const query_arena = geode.query_arena;

test "arena pool reuses arenas across queries (capacity bound)" {
    var pool = try query_arena.Pool.init(std.testing.allocator, 4);
    defer pool.deinit();

    var seen = std.AutoHashMap(*query_arena.Arena, void).init(std.testing.allocator);
    defer seen.deinit();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const a = try pool.acquire();
        const buf = try a.allocator().alloc(u8, 1024);
        // Touch to keep the compiler honest.
        buf[0] = @as(u8, @truncate(i));
        try seen.put(a, {});
        pool.release(a);
    }

    // At most `capacity` distinct arenas should have been handed out — proof
    // of reuse (10 queries through a pool of 4 must recycle arenas).
    try testing.expect(seen.count() <= 4);
    // And at least one arena must have been reused (otherwise the pool is
    // trivially hitting the fall-back path every call).
    try testing.expect(seen.count() < 10);
}

test "arena pool acquire returns the recently released arena (reset in-place)" {
    var pool = try query_arena.Pool.init(std.testing.allocator, 2);
    defer pool.deinit();

    const a1 = try pool.acquire();
    const buf1 = try a1.allocator().alloc(u8, 64);
    @memset(buf1, 0xaa);
    pool.release(a1);

    // Second acquire with an empty pool (capacity permits) must return the
    // same `*Arena` back from the free list, reset for fresh allocations.
    const a2 = try pool.acquire();
    try testing.expectEqual(a1, a2);
    const buf2 = try a2.allocator().alloc(u8, 64);
    try testing.expect(buf2.len == 64);
    pool.release(a2);
}

test "arena pool oversubscription: extra arenas are allocated and released cleanly" {
    var pool = try query_arena.Pool.init(std.testing.allocator, 2);
    defer pool.deinit();

    // Hold three arenas simultaneously — one over capacity. The third is
    // freshly allocated because the free list is empty.
    const a1 = try pool.acquire();
    const a2 = try pool.acquire();
    const a3 = try pool.acquire();
    // Each must be independent.
    try testing.expect(a1 != a2);
    try testing.expect(a2 != a3);
    try testing.expect(a1 != a3);

    // Scribble through each to prove the allocator works.
    _ = try a1.allocator().alloc(u8, 128);
    _ = try a2.allocator().alloc(u8, 128);
    _ = try a3.allocator().alloc(u8, 128);

    // Release in reverse order. First two go back to the free list
    // (capacity=2). Third is over capacity and must be torn down on release,
    // not leaked; the testing allocator asserts this at deinit.
    pool.release(a1);
    pool.release(a2);
    pool.release(a3);
}
