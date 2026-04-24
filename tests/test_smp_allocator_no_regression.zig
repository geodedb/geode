// Regression test for GAP-0754 — graph_store.global_allocator is smp_allocator.
//
// Triage:  docs/superpowers/plans/2026-04-18-match-qps-close-gap.md (Task 2)
// Summary: Before GAP-0754 `graph_store.global_gpa` was a
//          `std.heap.DebugAllocator(.{})` whose internal mutex serialized every
//          alloc/free. After GAP-0753 narrowed the handler lock-hold window,
//          allocator contention became the next bottleneck on the MATCH hot
//          path. This test pins the contract that the graph_store global
//          allocator is `std.heap.smp_allocator` — a sharded per-core
//          allocator with thread-local fast paths.
//
// Test design (rewritten 2026-04-24):
//   Direct vtable-identity assertion. The previous design used a 100k
//   alloc/free timing loop with a 50 ms budget. Under contended CI hosts
//   (background builds, other test binaries, foreign workloads) that budget
//   flakes to 80–150 ms even with the correct smp_allocator installed, while
//   DebugAllocator's mutex-serialized path legitimately takes 200 ms+ on
//   quiet hosts. The budget-based test is strictly weaker than an identity
//   check: it fails-closed on load (false positive) and doesn't fail-fast on
//   a new mutex-heavy allocator that happens to finish under budget.
//
//   `std.mem.Allocator` is `{ ptr: *anyopaque, vtable: *const VTable }`. Two
//   allocators returning the same vtable pointer are the same allocator
//   implementation. `std.heap.smp_allocator` exposes its allocator via
//   `.allocator()` (a function) on some std versions and as a plain
//   `.allocator` variable on others; we handle both via a small helper.
//
//   Secondary sanity: a short functional loop actually allocates and frees
//   through the accessor, catching "vtable matches but wired to broken
//   implementation" regressions.
//
// CANARY: REQ=REQ-PERF-GRAPH-STORE-ALLOC-001; FEATURE="GraphStoreGlobalAllocator"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_smp_allocator_no_regression.zig:1; OWNER=storage; UPDATED=2026-04-24

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;

test "graph_store.global_allocator is std.heap.smp_allocator (not DebugAllocator)" {
    const alloc = graph_store.global_allocator();
    const smp = std.heap.smp_allocator;

    // Vtable identity is the contract. Same vtable pointer ⇒ same
    // allocator implementation. A DebugAllocator-backed Allocator carries
    // a DIFFERENT vtable and would fail this check immediately, whereas
    // the previous timing test would only catch it under sustained load.
    try testing.expectEqual(smp.vtable, alloc.vtable);

    // Functional smoke — verify the accessor actually allocates and frees
    // through the returned allocator. Catches the "vtable pointer matches
    // but allocator is in a broken state" failure mode. Small iteration
    // count so this stays fast on any host.
    const iters: usize = 1_000;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const buf = try alloc.alloc(u8, 64);
        buf[0] = @as(u8, @truncate(i));
        alloc.free(buf);
    }
}
